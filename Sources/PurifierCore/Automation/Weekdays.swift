// Weekdays for schedule rules. Raw encoding: bit (weekday - 1),
// where weekday is the Calendar.weekday value (1 = Sunday ... 7 = Saturday).
import Foundation

public struct Weekdays: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let sunday = Weekdays(rawValue: 1 << 0)
    public static let monday = Weekdays(rawValue: 1 << 1)
    public static let tuesday = Weekdays(rawValue: 1 << 2)
    public static let wednesday = Weekdays(rawValue: 1 << 3)
    public static let thursday = Weekdays(rawValue: 1 << 4)
    public static let friday = Weekdays(rawValue: 1 << 5)
    public static let saturday = Weekdays(rawValue: 1 << 6)

    public static let everyday: Weekdays = [
        .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday,
    ]

    /// Whether a day from `Calendar.weekday` (1 = Sunday) is in the set.
    public func contains(calendarWeekday: Int) -> Bool {
        guard (1...7).contains(calendarWeekday) else { return false }
        return rawValue & (1 << (calendarWeekday - 1)) != 0
    }

    /// Encoded as a single integer - rawValue, so that the JSON stays compact and stable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
