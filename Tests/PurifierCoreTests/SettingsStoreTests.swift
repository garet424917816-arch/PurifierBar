// Settings storage tests: round-trip, corrupted and missing file.
import Foundation
import Testing
@testable import PurifierCore

private func temporaryURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PurifierBarTests-\(UUID().uuidString)")
    return directory.appendingPathComponent("automation.json")
}

private let sample = AutomationSettings(
    schedule: [
        ScheduleRule(
            hour: 7, minute: 30, weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            action: ScheduleAction(power: true, mode: .auto)
        ),
        ScheduleRule(
            hour: 22, minute: 0, weekdays: .everyday,
            action: ScheduleAction(power: false)
        ),
        ScheduleRule(
            hour: 12, minute: 0, weekdays: [.saturday, .sunday],
            action: ScheduleAction(mode: .manual, manualLevel: 6)
        ),
    ],
    threshold: ThresholdSettings(isEnabled: true, pm25Limit: 42, riseDuration: 90, fallDuration: 300)
)

@Test func settingsRoundTrip() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SettingsStore(url: url)

    try store.save(sample)
    let loaded = store.load()
    #expect(loaded == sample)
}

@Test func loadMissingFileReturnsStandard() {
    let url = temporaryURL()
    let store = SettingsStore(url: url)
    #expect(store.load() == .standard)
}

@Test func loadCorruptedFileReturnsStandard() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("не json".utf8).write(to: url)

    let store = SettingsStore(url: url)
    #expect(store.load() == .standard)
}

@Test func saveIsAtomicAndOverwrites() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SettingsStore(url: url)

    try store.save(sample)
    var changed = sample
    changed.threshold.pm25Limit = 10
    try store.save(changed)

    #expect(store.load() == changed)
}

// MARK: - Codable of individual types

@Test func scheduleActionCodableRoundTrip() throws {
    let actions = [
        ScheduleAction(),
        ScheduleAction(power: false),
        ScheduleAction(power: true, mode: .sleep),
        ScheduleAction(mode: .manual, manualLevel: 14),
    ]
    for action in actions {
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(ScheduleAction.self, from: data)
        #expect(decoded == action)
    }
}

@Test func weekdaysCodableRoundTrip() throws {
    let weekdays: Weekdays = [.monday, .friday, .sunday]
    let data = try JSONEncoder().encode(weekdays)
    let decoded = try JSONDecoder().decode(Weekdays.self, from: data)
    #expect(decoded == weekdays)
    #expect(decoded.contains(calendarWeekday: 2))
    #expect(!decoded.contains(calendarWeekday: 3))
}
