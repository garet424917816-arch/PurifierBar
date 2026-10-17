// Typed purifier state; property identifiers and encodings belong to PurifierLayout.
import Foundation

/// Operating mode of the purifier. `.manual` is "Favorite" in the app.
public enum PurifierMode: Int, Sendable, CaseIterable {
    case auto = 0
    case sleep = 1
    case manual = 2
}

/// Semantic brightness; raw values are encoded by the device layout.
public enum ScreenBrightness: Int, Sendable, CaseIterable {
    case off = 0
    case dim = 1
    case bright = 2
}

/// Semantic device fault; raw codes are decoded by the device layout.
public enum PurifierFault: Sendable, Equatable {
    case none
    case motorStuck
    case sensorLost
    case other(Int)
}

/// Full typed state of the purifier.
public struct PurifierState: Sendable, Equatable {
    public var isOn: Bool
    public var fault: PurifierFault
    /// Nil when the device reports a mode the app does not model.
    public var mode: PurifierMode?
    public var pm25: Int
    public var filterPercent: Int
    public var filterHoursUsed: Int
    /// Nil for layouts without a remaining-days property.
    public var filterDaysLeft: Int?
    public var sound: Bool
    public var childLock: Bool
    public var screen: ScreenBrightness
    public var motorRPM: Int
    public var favoriteLevel: Int

    public init(
        isOn: Bool,
        fault: PurifierFault,
        mode: PurifierMode?,
        pm25: Int,
        filterPercent: Int,
        filterHoursUsed: Int,
        filterDaysLeft: Int?,
        sound: Bool,
        childLock: Bool,
        screen: ScreenBrightness,
        motorRPM: Int,
        favoriteLevel: Int
    ) {
        self.isOn = isOn
        self.fault = fault
        self.mode = mode
        self.pm25 = pm25
        self.filterPercent = filterPercent
        self.filterHoursUsed = filterHoursUsed
        self.filterDaysLeft = filterDaysLeft
        self.sound = sound
        self.childLock = childLock
        self.screen = screen
        self.motorRPM = motorRPM
        self.favoriteLevel = favoriteLevel
    }
}

/// State-change command. `.manualLevel` - Manual mode and level in one write.
public enum PurifierCommand: Sendable, Equatable {
    case power(Bool)
    case mode(PurifierMode)
    case favoriteLevel(Int)
    case sound(Bool)
    case childLock(Bool)
    case screen(ScreenBrightness)
    case manualLevel(Int)
}

/// Device-level errors (not transport).
public enum DeviceError: Error, Sendable, Equatable {
    case superseded         // a newer send owns confirmation and publication
    case invalidValue       // a level outside the device range never reaches the network
    case incompleteState    // a required property is missing or has an invalid type
    case notConfirmed       // written, but read-back did not confirm within the allotted time
}

// MARK: - State and command matching (read-back, fake device)

extension PurifierState {
    /// Whether the state matches the command. For `.manualLevel` - both mode and level.
    func matches(_ command: PurifierCommand) -> Bool {
        switch command {
        case .power(let value): return isOn == value
        case .mode(let mode): return self.mode == mode
        case .favoriteLevel(let level): return favoriteLevel == level
        case .sound(let value): return sound == value
        case .childLock(let value): return childLock == value
        case .screen(let value): return screen == value
        case .manualLevel(let level): return mode == .manual && favoriteLevel == level
        }
    }

    /// State after applying a command (for the fake device in tests).
    func applying(_ command: PurifierCommand) -> PurifierState {
        var copy = self
        switch command {
        case .power(let value): copy.isOn = value
        case .mode(let mode): copy.mode = mode
        case .favoriteLevel(let level): copy.favoriteLevel = level
        case .sound(let value): copy.sound = value
        case .childLock(let value): copy.childLock = value
        case .screen(let value): copy.screen = value
        case .manualLevel(let level):
            copy.mode = .manual
            copy.favoriteLevel = level
        }
        return copy
    }
}
