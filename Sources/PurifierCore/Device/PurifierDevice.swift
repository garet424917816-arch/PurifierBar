// Device abstraction: the real one goes through MIoTClient, in tests - a fake.
import Foundation

/// Device abstraction: the real one goes through MIoTClient, in tests - a fake.
public protocol PurifierDevice: Sendable {
    func readState() async throws -> PurifierState
    /// One set_properties, without read-back.
    func apply(_ command: PurifierCommand) async throws
}

/// The real device over the MIoT client.
public struct MIoTPurifier: PurifierDevice {
    private let client: MIoTClient
    public let layout: PurifierLayout

    public init(client: MIoTClient, layout: PurifierLayout = .cpa4) {
        self.layout = layout
        self.client = client
    }

    public func readState() async throws -> PurifierState {
        let values = try await client.get(layout.all)

        func int(_ id: PropertyID) throws -> Int {
            guard case .int(let value)? = values[id] else { throw DeviceError.incompleteState }
            return value
        }
        func bool(_ id: PropertyID) throws -> Bool {
            guard case .bool(let value)? = values[id] else { throw DeviceError.incompleteState }
            return value
        }

        let mode = PurifierMode(rawValue: try int(layout.mode))
        guard let screen = layout.screenBrightness(value: try int(layout.screen)) else {
            throw DeviceError.incompleteState
        }

        let favoriteLevel = try int(layout.favoriteLevel)
        guard layout.favoriteLevelRange.contains(favoriteLevel) else {
            throw DeviceError.invalidValue
        }

        return PurifierState(
            isOn: try bool(layout.power),
            fault: layout.purifierFault(code: try int(layout.fault)),
            mode: mode,
            pm25: try int(layout.pm25),
            filterPercent: try int(layout.filterPercent),
            filterHoursUsed: try int(layout.filterHoursUsed),
            filterDaysLeft: try layout.filterDaysLeft.map { try int($0) },
            sound: try bool(layout.sound),
            childLock: try bool(layout.childLock),
            screen: screen,
            motorRPM: try int(layout.motorRPM),
            favoriteLevel: favoriteLevel
        )
    }

    public func apply(_ command: PurifierCommand) async throws {
        try command.validated(layout: layout)
        try await client.set(command.writes(layout: layout))
    }
}

// MARK: - Translating a command into properties

extension PurifierCommand {
    /// Properties for one set_properties. `.manualLevel` writes mode and level together.
    func writes(layout: PurifierLayout = .cpa4) -> [(PropertyID, MIoTValue)] {
        switch self {
        case .power(let value):
            return [(layout.power, .bool(value))]
        case .mode(let mode):
            return [(layout.mode, .int(mode.rawValue))]
        case .favoriteLevel(let level):
            return [(layout.favoriteLevel, .int(level))]
        case .sound(let value):
            return [(layout.sound, .bool(value))]
        case .childLock(let value):
            return [(layout.childLock, .bool(value))]
        case .screen(let value):
            return [(layout.screen, .int(layout.screenValue(value)))]
        case .manualLevel(let level):
            return [(layout.mode, .int(PurifierMode.manual.rawValue)),
                    (layout.favoriteLevel, .int(level))]
        }
    }

    /// Check the device range before any network call.
    func validated(layout: PurifierLayout = .cpa4) throws {
        switch self {
        case .favoriteLevel(let level), .manualLevel(let level):
            guard layout.favoriteLevelRange.contains(level) else { throw DeviceError.invalidValue }
        default:
            break
        }
    }
}
