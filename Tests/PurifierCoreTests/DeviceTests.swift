// Tests of the MIoTPurifier mapping: reading 12 properties, command translation, ranges.
import Foundation
import Testing
@testable import PurifierCore

/// Fake transport: returns pre-prepared replies and remembers the calls.
private actor RecordingTransport: MiIOTransport {
    private var replies: [Data]
    private(set) var calls: [(method: String, params: Data)] = []

    init(replies: [Data]) { self.replies = replies }

    func call(method: String, params: Data) async throws -> Data {
        calls.append((method, params))
        guard !replies.isEmpty else { throw MiIOError.timeout }
        return replies.removeFirst()
    }
}

private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func row(_ siid: Int, _ piid: Int, _ value: Any) -> [String: Any] {
    ["did": "123456789", "siid": siid, "piid": piid, "code": 0, "value": value]
}

private func successSetReply() throws -> Data {
    try json(["id": 1, "result": [["did": "123456789", "siid": 2, "piid": 1, "code": 0]]])
}

/// The reference state given by `fullReadReply`.
private let sampleState = PurifierState(
    isOn: true,
    fault: .sensorLost,
    mode: .manual,
    pm25: 149,
    filterPercent: 64,
    filterHoursUsed: 100,
    filterDaysLeft: 186,
    sound: false,
    childLock: true,
    screen: .off,
    motorRPM: 416,
    favoriteLevel: 9
)

/// Full get_properties reply with literal siid.piid - independent of the code.
/// `favoriteLevel` - the value of 9.11 in the reply.
private func fullReadReply(favoriteLevel: Int = 9) throws -> Data {
    try json(["id": 1, "result": [
        row(2, 1, true),
        row(2, 2, 3),
        row(2, 4, 2),
        row(3, 4, 149),
        row(4, 1, 64),
        row(4, 3, 100),
        row(4, 4, 186),
        row(6, 1, false),
        row(8, 1, true),
        row(9, 1, 416),
        row(9, 11, favoriteLevel),
        row(13, 2, 0),
    ]])
}

private func makePurifier(_ transport: RecordingTransport) -> MIoTPurifier {
    MIoTPurifier(client: MIoTClient(transport: transport, deviceID: "123456789"))
}

// MARK: - Reading

@Test func readStateMapsAllTwelveProperties() async throws {
    let transport = RecordingTransport(replies: [try fullReadReply()])
    let state = try await makePurifier(transport).readState()
    #expect(state == sampleState)

    let calls = await transport.calls
    #expect(calls.count == 1)
    #expect(calls[0].method == "get_properties")
    let params = try JSONSerialization.jsonObject(with: calls[0].params) as? [[String: Any]]
    #expect(params?.count == 12)
    let ids = Set((params ?? []).compactMap { item -> String? in
        guard let siid = item["siid"] as? Int, let piid = item["piid"] as? Int else { return nil }
        return "\(siid).\(piid)"
    })
    #expect(ids == ["2.1", "2.2", "2.4", "3.4", "4.1", "4.3", "4.4", "6.1", "8.1", "9.1", "9.11", "13.2"])
    #expect(!ids.contains("9.10"))
    #expect(!ids.contains("9.12"))
}

@Test func readStateRejectsMissingProperty() async throws {
    // Missing 4.4 (filter_days).
    let reply = try json(["id": 1, "result": [
        row(2, 1, true), row(2, 2, 0), row(2, 4, 0), row(3, 4, 10),
        row(4, 1, 50), row(4, 3, 10), row(6, 1, true), row(8, 1, false),
        row(9, 1, 100), row(9, 11, 5), row(13, 2, 1),
    ]])
    let transport = RecordingTransport(replies: [reply])
    await #expect(throws: DeviceError.incompleteState) {
        _ = try await makePurifier(transport).readState()
    }
}

@Test func readStatePreservesUnrepresentableMode() async throws {
    let reply = try json(["id": 1, "result": [
        row(2, 1, true), row(2, 2, 0), row(2, 4, 7), row(3, 4, 10),
        row(4, 1, 50), row(4, 3, 10), row(4, 4, 186), row(6, 1, true),
        row(8, 1, false), row(9, 1, 100), row(9, 11, 5), row(13, 2, 1),
    ]])
    let transport = RecordingTransport(replies: [reply])
    let state = try await makePurifier(transport).readState()
    #expect(state.mode == nil)
    #expect(state.pm25 == 10)
}

@Test func readStateAcceptsBoundaryFavoriteLevels() async throws {
    for level in [0, 14] {
        let transport = RecordingTransport(replies: [try fullReadReply(favoriteLevel: level)])
        let state = try await makePurifier(transport).readState()
        #expect(state.favoriteLevel == level)
    }
}

@Test func readStateRejectsOutOfRangeFavoriteLevel() async throws {
    // 9.11 outside 0...14 is invalid: the value further drives the slider and the glow (T13).
    for level in [15, -1, Int.max] {
        let transport = RecordingTransport(replies: [try fullReadReply(favoriteLevel: level)])
        await #expect(throws: DeviceError.invalidValue) {
            _ = try await makePurifier(transport).readState()
        }
    }
}

// MARK: - Writing

/// Runs `apply` and returns the params of the set_properties call.
private func appliedParams(_ command: PurifierCommand) async throws -> [[String: Any]] {
    let transport = RecordingTransport(replies: [try successSetReply()])
    try await makePurifier(transport).apply(command)
    let calls = await transport.calls
    #expect(calls.count == 1)
    #expect(calls[0].method == "set_properties")
    return try JSONSerialization.jsonObject(with: calls[0].params) as? [[String: Any]] ?? []
}

@Test func applyMapsSinglePropertyCommands() async throws {
    let power = try await appliedParams(.power(false))
    #expect(power.count == 1)
    #expect(power[0]["siid"] as? Int == 2)
    #expect(power[0]["piid"] as? Int == 1)
    #expect(power[0]["value"] as? Bool == false)

    let mode = try await appliedParams(.mode(.sleep))
    #expect(mode[0]["siid"] as? Int == 2)
    #expect(mode[0]["piid"] as? Int == 4)
    #expect(mode[0]["value"] as? Int == 1)

    let favorite = try await appliedParams(.favoriteLevel(7))
    #expect(favorite[0]["siid"] as? Int == 9)
    #expect(favorite[0]["piid"] as? Int == 11)
    #expect(favorite[0]["value"] as? Int == 7)

    let sound = try await appliedParams(.sound(true))
    #expect(sound[0]["siid"] as? Int == 6)
    #expect(sound[0]["piid"] as? Int == 1)
    #expect(sound[0]["value"] as? Bool == true)

    let lock = try await appliedParams(.childLock(true))
    #expect(lock[0]["siid"] as? Int == 8)
    #expect(lock[0]["piid"] as? Int == 1)
    #expect(lock[0]["value"] as? Bool == true)

    let screen = try await appliedParams(.screen(.dim))
    #expect(screen[0]["siid"] as? Int == 13)
    #expect(screen[0]["piid"] as? Int == 2)
    #expect(screen[0]["value"] as? Int == 1)
}

@Test func applyMapsManualLevelAsTwoProperties() async throws {
    let params = try await appliedParams(.manualLevel(14))
    #expect(params.count == 2)
    var byID: [String: Any] = [:]
    for item in params {
        guard let siid = item["siid"] as? Int, let piid = item["piid"] as? Int else { continue }
        byID["\(siid).\(piid)"] = item["value"]
    }
    #expect(byID["2.4"] as? Int == PurifierMode.manual.rawValue)
    #expect(byID["9.11"] as? Int == 14)
}

@Test func applyRejectsLevelOutOfRangeWithoutNetwork() async throws {
    let transport = RecordingTransport(replies: [try successSetReply()])
    let purifier = makePurifier(transport)

    await #expect(throws: DeviceError.invalidValue) { try await purifier.apply(.favoriteLevel(15)) }
    await #expect(throws: DeviceError.invalidValue) { try await purifier.apply(.favoriteLevel(-1)) }
    await #expect(throws: DeviceError.invalidValue) { try await purifier.apply(.manualLevel(15)) }
    #expect(await transport.calls.isEmpty)
}
