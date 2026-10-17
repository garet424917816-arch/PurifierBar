// Schedule: the rule action, the rule itself and the search for the nearest trigger.
import Foundation

/// Rule action: any combination of on/off, mode and Manual level.
public struct ScheduleAction: Codable, Sendable, Equatable {
    public var power: Bool?        // nil = do not change
    public var mode: PurifierMode? // nil = do not change
    public var manualLevel: Int?   // only together with mode == .manual; 0...14

    public init(power: Bool? = nil, mode: PurifierMode? = nil, manualLevel: Int? = nil) {
        self.power = power
        self.mode = mode
        self.manualLevel = manualLevel
    }

    /// Sequence of commands to apply the action.
    /// Power-off is self-sufficient: nothing further is written.
    public var commands: [PurifierCommand] {
        if power == false { return [.power(false)] }
        var result: [PurifierCommand] = []
        if power == true { result.append(.power(true)) }
        if let mode {
            if mode == .manual, let manualLevel {
                result.append(.manualLevel(manualLevel))
            } else {
                result.append(.mode(mode))
            }
        }
        return result
    }

    // PurifierMode is not Codable (T1/T2 untouched), so the mode is encoded as a raw Int.
    private enum CodingKeys: String, CodingKey {
        case power, mode, manualLevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        power = try container.decodeIfPresent(Bool.self, forKey: .power)
        if let raw = try container.decodeIfPresent(Int.self, forKey: .mode) {
            guard let parsed = PurifierMode(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: container,
                    debugDescription: "unknown mode: \(raw)"
                )
            }
            mode = parsed
        } else {
            mode = nil
        }
        manualLevel = try container.decodeIfPresent(Int.self, forKey: .manualLevel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(power, forKey: .power)
        try container.encodeIfPresent(mode?.rawValue, forKey: .mode)
        try container.encodeIfPresent(manualLevel, forKey: .manualLevel)
    }
}

/// Rule: time (hour:minute) + weekdays -> action.
public struct ScheduleRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int
    public var weekdays: Weekdays
    public var action: ScheduleAction

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        hour: Int = 0,
        minute: Int = 0,
        weekdays: Weekdays = .everyday,
        action: ScheduleAction = ScheduleAction()
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.action = action
    }
}

public enum Schedule {
    /// The nearest trigger moment of any enabled rule strictly after `date`.
    /// Returns that moment and all rules that trigger at it (in the order of the input list).
    /// `nil` - no enabled rule will fire.
    public static func nextFire(
        after date: Date,
        rules: [ScheduleRule],
        calendar: Calendar
    ) -> (date: Date, rules: [ScheduleRule])? {
        var candidates: [Int: Date] = [:]
        for (index, rule) in rules.enumerated() where rule.isEnabled {
            guard (0...23).contains(rule.hour), (0...59).contains(rule.minute) else { continue }
            guard let candidate = nextOccurrence(of: rule, after: date, calendar: calendar) else { continue }
            candidates[index] = candidate
        }
        guard let earliest = candidates.values.min() else { return nil }
        let firing = rules.enumerated()
            .filter { candidates[$0.offset] == earliest }
            .map(\.element)
        return (earliest, firing)
    }

    /// The first day (0...7 days ahead) on which the rule fires strictly after `date`.
    /// The week repeats every 7 days, so 8 days cover the case for certain.
    private static func nextOccurrence(
        of rule: ScheduleRule,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        let dayStart = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: dayStart) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard rule.weekdays.contains(calendarWeekday: weekday) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = rule.hour
            components.minute = rule.minute
            components.second = 0
            guard let candidate = calendar.date(from: components), candidate > date else { continue }
            return candidate
        }
        return nil
    }
}
