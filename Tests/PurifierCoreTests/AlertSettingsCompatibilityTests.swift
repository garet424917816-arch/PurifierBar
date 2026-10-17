// Settings compatibility: T4 files without the `alerts` key are read, not reset.
import Foundation
import Testing
@testable import PurifierCore

/// JSON in the T4 format: without the `alerts` key.
private let legacyJSON = """
{
  "schedule": [
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "isEnabled": true,
      "hour": 7,
      "minute": 30,
      "weekdays": 62,
      "action": { "power": true, "mode": 0 }
    }
  ],
  "threshold": { "isEnabled": true, "pm25Limit": 42, "riseDuration": 90, "fallDuration": 300 }
}
"""

@Test func legacyJSONKeepsScheduleAndThresholdAddsStandardAlerts() throws {
    let decoded = try JSONDecoder().decode(AutomationSettings.self, from: Data(legacyJSON.utf8))

    #expect(decoded.alerts == .standard)
    #expect(decoded.threshold == ThresholdSettings(
        isEnabled: true, pm25Limit: 42, riseDuration: 90, fallDuration: 300
    ))
    #expect(decoded.schedule.count == 1)
    #expect(decoded.schedule[0].hour == 7)
    #expect(decoded.schedule[0].minute == 30)
    #expect(decoded.schedule[0].weekdays == [.monday, .tuesday, .wednesday, .thursday, .friday])
    #expect(decoded.schedule[0].action == ScheduleAction(power: true, mode: .auto))
}

@Test func legacyFileLoadsThroughStore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PurifierBarAlertCompat-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("automation.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(legacyJSON.utf8).write(to: url)

    let loaded = SettingsStore(url: url).load()
    #expect(loaded.alerts == .standard)
    #expect(loaded.threshold.pm25Limit == 42)
    #expect(loaded.schedule.count == 1)
}

@Test func alertsRoundTripWithOtherSettings() throws {
    let custom = AutomationSettings(
        schedule: [ScheduleRule(hour: 8, minute: 0)],
        threshold: ThresholdSettings(pm25Limit: 50),
        alerts: AlertSettings(filterLow: false, fault: true, unreachable: false, unreachableMinutes: 30)
    )
    let data = try JSONEncoder().encode(custom)
    let decoded = try JSONDecoder().decode(AutomationSettings.self, from: data)
    #expect(decoded == custom)
}
