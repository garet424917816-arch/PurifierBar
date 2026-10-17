// Formatting of panel and menu bar lines. Pure functions only - easy to test.
import Foundation

public enum PanelFormat {
    /// Menu bar label: "18", "18?" when there is no connectivity, "-" when there is no state.
    public static func menuBarTitle(pm25: Int?, connection: Connection) -> String {
        guard let pm25 else { return "—" }
        return connection == .unreachable ? "\(pm25)?" : "\(pm25)"
    }

    /// Filter life: "64 % · 186 d.".
    public static func filter(percent: Int, daysLeft: Int?) -> String {
        guard let daysLeft else { return String(localized: "\(percent) %") }
        return String(localized: "\(percent) % · \(daysLeft) d")
    }

    public static func mode(_ mode: PurifierMode) -> String {
        switch mode {
        case .auto: return String(localized: "Auto")
        case .sleep: return String(localized: "Sleep")
        case .manual: return String(localized: "Manual")
        }
    }

    public static func screen(_ screen: ScreenBrightness) -> String {
        switch screen {
        case .off: return String(localized: "Off")
        case .bright: return String(localized: "Bright")
        case .dim: return String(localized: "Dim")
        }
    }

    // MARK: - Schedule

    /// Short day names Mon..Sun with the corresponding `Weekdays` bits.
    private static let weekdayNames: [(day: Weekdays, title: String)] = [
        (.monday, String(localized: "Mon")),
        (.tuesday, String(localized: "Tue")),
        (.wednesday, String(localized: "Wed")),
        (.thursday, String(localized: "Thu")),
        (.friday, String(localized: "Fri")),
        (.saturday, String(localized: "Sat")),
        (.sunday, String(localized: "Sun")),
    ]

    /// Weekdays (Mon-Fri) and weekend (Sat, Sun) - for the summary labels.
    public static let weekdays: Weekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekends: Weekdays = [.saturday, .sunday]

    /// Label of a day set: "Daily", "Weekdays", "Weekend", "No days",
    /// otherwise abbreviations separated by spaces in order Mon..Sun.
    public static func scheduleWeekdays(_ days: Weekdays) -> String {
        if days == .everyday { return String(localized: "Every day") }
        if days == weekdays { return String(localized: "Weekdays") }
        if days == weekends { return String(localized: "Weekends") }
        if days.isEmpty { return String(localized: "No days") }
        return weekdayNames.filter { days.contains($0.day) }.map(\.title).joined(separator: " ")
    }

    /// Label of a rule's action: power and mode joined by " · "; an empty action is "No change".
    public static func scheduleAction(_ action: ScheduleAction) -> String {
        var parts: [String] = []
        switch action.power {
        case .some(true): parts.append(String(localized: "On"))
        case .some(false): parts.append(String(localized: "Off"))
        case .none: break
        }
        if let actionMode = action.mode {
            // The level makes sense only for manual mode; the mode name is as in `mode`.
            if actionMode == .manual, let level = action.manualLevel {
                parts.append("\(mode(actionMode)) \(level)")
            } else {
                parts.append(mode(actionMode))
            }
        }
        return parts.isEmpty ? String(localized: "No change") : parts.joined(separator: " · ")
    }

    /// Rule time in the "07:05" format.
    public static func scheduleTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// The nearest schedule event ("today 22:00", "tomorrow 07:00", "Fri 07:00")
    /// without an action; `nil` - no enabled rule will fire.
    public static func scheduleNext(
        after now: Date,
        rules: [ScheduleRule],
        calendar: Calendar
    ) -> String? {
        guard let fire = Schedule.nextFire(after: now, rules: rules, calendar: calendar) else {
            return nil
        }
        let time = scheduleTime(
            hour: calendar.component(.hour, from: fire.date),
            minute: calendar.component(.minute, from: fire.date)
        )
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: fire.date)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        switch days {
        case 0: return String(localized: "today \(time)")
        case 1: return String(localized: "tomorrow \(time)")
        default:
            let weekday = calendar.component(.weekday, from: fire.date)
            let title = weekdayNames.first { $0.day.contains(calendarWeekday: weekday) }?.title ?? ""
            return "\(title) \(time)"
        }
    }

    /// Device error description; `nil` - no error.
    public static func fault(_ fault: PurifierFault) -> String? {
        switch fault {
        case .none: return nil
        case .motorStuck: return String(localized: "Motor stuck")
        case .sensorLost: return String(localized: "Sensor lost")
        case .other(let code): return String(localized: "Error \(code)")
        }
    }
}
