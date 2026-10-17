// Notifications about purifier events: kinds, toggle settings and memory,
// which survives an app restart.
import Foundation

/// An event worth telling the user about.
public enum PurifierAlert: Sendable, Equatable {
    /// Filter life dropped below the threshold. `percent` - the value at the time of the notification.
    case filterLow(percent: Int)
    /// Device malfunction (2.2). Never `.none`.
    case fault(PurifierFault)
    /// The device has been unavailable since `since` (the start of the episode).
    case unreachable(since: Date)
}

/// Notification toggles and the unavailability threshold.
public struct AlertSettings: Codable, Sendable, Equatable {
    public var filterLow: Bool
    public var fault: Bool
    public var unreachable: Bool
    /// How many minutes of unavailability count as a reason for a notification.
    /// Used clamped to `1...240`.
    public var unreachableMinutes: Int

    public static let standard = AlertSettings(
        filterLow: true,
        fault: true,
        unreachable: true,
        unreachableMinutes: 10
    )

    public init(filterLow: Bool, fault: Bool, unreachable: Bool, unreachableMinutes: Int) {
        self.filterLow = filterLow
        self.fault = fault
        self.unreachable = unreachable
        self.unreachableMinutes = unreachableMinutes
    }

    /// Minutes within `1...240` - protection against nonsense values in the file.
    var clampedMinutes: Int {
        min(max(unreachableMinutes, 1), 240)
    }
}

/// What must survive an app restart. Stored separately from the settings.
public struct AlertMemory: Codable, Sendable, Equatable {
    /// Already notified about low filter life; reset after the filter is replaced.
    public var filterLowNotified: Bool

    public init(filterLowNotified: Bool = false) {
        self.filterLowNotified = filterLowNotified
    }
}
