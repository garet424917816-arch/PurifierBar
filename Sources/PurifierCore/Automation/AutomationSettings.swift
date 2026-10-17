// Saved automation settings and their atomic save to disk.
import Foundation

public struct AutomationSettings: Codable, Sendable, Equatable {
    public var schedule: [ScheduleRule]
    public var threshold: ThresholdSettings
    public var alerts: AlertSettings

    public static let standard = AutomationSettings(schedule: [], threshold: .standard, alerts: .standard)

    public init(
        schedule: [ScheduleRule] = [],
        threshold: ThresholdSettings = .standard,
        alerts: AlertSettings = .standard
    ) {
        self.schedule = schedule
        self.threshold = threshold
        self.alerts = alerts
    }

    private enum CodingKeys: String, CodingKey {
        case schedule, threshold, alerts
    }

    /// Files written before the notifications appeared have no `alerts` key:
    /// then we take `.standard` and do not reset the whole file content.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try container.decodeIfPresent([ScheduleRule].self, forKey: .schedule) ?? []
        threshold = try container.decodeIfPresent(ThresholdSettings.self, forKey: .threshold) ?? .standard
        alerts = try container.decodeIfPresent(AlertSettings.self, forKey: .alerts) ?? .standard
    }
}

/// Settings file. Any read or parse problem -> `.standard`.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Default file location: `Application Support/PurifierBar/automation.json`.
    /// Shared by the app and the settings process, so the path lives in one place.
    public static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PurifierBar", isDirectory: true)
            .appendingPathComponent("automation.json")
    }

    public func load() -> AutomationSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AutomationSettings.self, from: data)
        else {
            return .standard
        }
        return settings
    }

    /// Atomic write: a temp file + replace, so as not to leave a corrupted file.
    public func save(_ settings: AutomationSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(settings)
        try data.write(to: url, options: .atomic)
    }
}
