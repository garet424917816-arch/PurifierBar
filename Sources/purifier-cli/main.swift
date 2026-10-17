// Diagnostic CLI - phases T1 and T2.
import Foundation
import Darwin
import Observation
import PurifierCore

/// Empty - without an IP (`--host`) the device is found by broadcast on each network interface.
private let defaultHost = ""

/// The 11 v1 properties from the README table.
private let properties: [(id: PropertyID, name: String)] = [
    (PropertyID(siid: 2, piid: 1), "on"),
    (PropertyID(siid: 2, piid: 2), "fault"),
    (PropertyID(siid: 2, piid: 4), "mode"),
    (PropertyID(siid: 3, piid: 4), "pm25"),
    (PropertyID(siid: 4, piid: 1), "filter_%"),
    (PropertyID(siid: 4, piid: 4), "filter_days"),
    (PropertyID(siid: 6, piid: 1), "sound"),
    (PropertyID(siid: 8, piid: 1), "child_lock"),
    (PropertyID(siid: 13, piid: 2), "screen"),
    (PropertyID(siid: 9, piid: 1), "rpm"),
    (PropertyID(siid: 9, piid: 11), "fav_level"),
]

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func format(_ value: MIoTValue?) -> String {
    switch value {
    case .bool(let flag): return flag ? "true" : "false"
    case .int(let number): return String(number)
    case nil: return "?"
    }
}

private func parsePropertyID(_ text: String) -> PropertyID? {
    let parts = text.split(separator: ".")
    guard parts.count == 2, let siid = Int(parts[0]), let piid = Int(parts[1]) else { return nil }
    return PropertyID(siid: siid, piid: piid)
}

private func parseValue(_ text: String) -> MIoTValue? {
    if text == "true" { return .bool(true) }
    if text == "false" { return .bool(false) }
    if let number = Int(text) { return .int(number) }
    return nil
}

/// Token from Keychain; the device id is read from the hello handshake. The token is not printed.
private func makeClient(host: String) async throws -> MIoTClient {
    let transport = try UDPTransport(host: host, token: TokenStore.load())
    let deviceID = try await transport.resolveDeviceID()
    return MIoTClient(transport: transport, deviceID: String(deviceID))
}

private func runGet(host: String) async throws {
    let client = try await makeClient(host: host)
    let values = try await client.get(properties.map(\.id))
    for property in properties {
        let name = property.name.padding(toLength: 12, withPad: " ", startingAt: 0)
        print("\(name)\(format(values[property.id]))")
    }
}

/// Diagnostics accept the fallback map explicitly; the app requires consent for unknown models.
private func deviceInfo(client: MIoTClient) async -> (model: String?, layout: PurifierLayout) {
    let model = try? await client.model()
    let decision = SupportedModels.decision(for: model, acceptedUnverifiedModel: model)
    return (model, SupportedModels.layout(for: model, decision: decision) ?? .cpa4)
}

private func runStatus(host: String) async throws {
    let client = try await makeClient(host: host)
    let info = await deviceInfo(client: client)
    let layout = info.layout
    let state = try await MIoTPurifier(client: client, layout: layout).readState()
    print("model        \(info.model ?? "unknown")")
    print("layout       \(layout.name)")
    print("on           \(state.isOn)")
    print("mode         \(modeName(state.mode))")
    print("fault        \(state.fault)")
    print("pm25         \(state.pm25)")
    print("filter_%     \(state.filterPercent)")
    print("filter_hours \(state.filterHoursUsed)")
    if let days = state.filterDaysLeft { print("filter_days  \(days)") }
    print("sound        \(state.sound)")
    print("child_lock   \(state.childLock)")
    print("screen       \(state.screen)")
    print("rpm          \(state.motorRPM)")
    print("fav_level    \(state.favoriteLevel)")
}

private func runSet(host: String, id: PropertyID, value: MIoTValue) async throws {
    let client = try await makeClient(host: host)
    try await client.set([(id, value)])
    // Read-back: we show what the device confirmed, not what was requested.
    let readBack = try await client.get([id])
    print("\(id) \(format(readBack[id]))")
}

// MARK: - watch

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func modeName(_ mode: PurifierMode?) -> String {
    switch mode {
    case .auto: return "auto"
    case .sleep: return "sleep"
    case .manual: return "manual"
    case nil: return "unknown"
    }
}

private func connectionName(_ connection: Connection) -> String {
    switch connection {
    case .connecting: return "connecting"
    case .online: return "online"
    case .unreachable: return "unreachable"
    }
}

/// A line for each change of state or connectivity: `HH:mm:ss online on auto 18 416`.
private func watchLine(connection: Connection, state: PurifierState?) -> String {
    let time = timeFormatter.string(from: Date())
    guard let state else { return "\(time) \(connectionName(connection))" }
    let power = state.isOn ? "on" : "off"
    return "\(time) \(connectionName(connection)) \(power) \(modeName(state.mode)) \(state.pm25) \(state.motorRPM)"
}

@MainActor
private func runWatch(host: String, open: Bool) async throws {
    let client = try await makeClient(host: host)
    let info = await deviceInfo(client: client)
    let controller = PurifierController(device: MIoTPurifier(client: client, layout: info.layout))
    controller.isPanelOpen = open
    controller.start()

    var lastConnection: Connection?
    var lastState: PurifierState?

    func render() {
        let connection = controller.connection
        let state = controller.state
        guard connection != lastConnection || state != lastState else { return }
        lastConnection = connection
        lastState = state
        print(watchLine(connection: connection, state: state))
        fflush(stdout)
    }

    render()
    // We react only to changes in the observed properties - no own loop and no timers.
    while true {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = controller.connection
                _ = controller.state
            } onChange: {
                continuation.resume()
            }
        }
        render()
    }
}

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
var host = defaultHost
if let index = arguments.firstIndex(of: "--host"), index + 1 < arguments.count {
    host = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}
var open = false
if let index = arguments.firstIndex(of: "--open") {
    open = true
    arguments.remove(at: index)
}

do {
    switch arguments.first {
    case "status":
        try await runStatus(host: host)
    case "get":
        try await runGet(host: host)
    case "set":
        guard arguments.count == 3, let id = parsePropertyID(arguments[1]) else {
            fail("usage: purifier-cli set <siid.piid> <true|false|number> [--host IP]")
        }
        guard let value = parseValue(arguments[2]) else {
            fail("value must be true, false or an integer")
        }
        try await runSet(host: host, id: id, value: value)
    case "watch":
        try await runWatch(host: host, open: open)
    default:
        fail("usage: purifier-cli status|get|set|watch [--open] [--host IP]")
    }
} catch {
    fail("error: \(error)")
}
