// Independent T4 probes per BRIEFS/T4_CONTRACT.md. The automation implementation is not used.
import Foundation
import Synchronization
import Testing
@testable import PurifierCore

private func t4State(
    pm25: Int = 36, isOn: Bool = true, mode: PurifierMode = .auto, level: Int = 7
) -> PurifierState {
    PurifierState(
        isOn: isOn, fault: .none, mode: mode, pm25: pm25,
        filterPercent: 64, filterHoursUsed: 100, filterDaysLeft: 186,
        sound: false, childLock: false, screen: .bright, motorRPM: 416,
        favoriteLevel: level
    )
}

private func t4Threshold(
    enabled: Bool = true, limit: Int = 35, rise: TimeInterval = 120, fall: TimeInterval = 600
) -> ThresholdSettings {
    var settings = ThresholdSettings.standard
    settings.isEnabled = enabled
    settings.pm25Limit = limit
    settings.riseDuration = rise
    settings.fallDuration = fall
    return settings
}

private func t4Settings(
    threshold: ThresholdSettings = t4Threshold(), rules: [ScheduleRule] = []
) -> AutomationSettings {
    var settings = AutomationSettings.standard
    settings.threshold = threshold
    settings.schedule = rules
    return settings
}

private let t4Epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func t4Date(_ text: String) -> Date {
    // All literals contain a zone; no dependency on the system calendar.
    ISO8601DateFormatter().date(from: text)!
}

private func t4Calendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func t4Rule(
    hour: Int = 10, minute: Int = 0, days: Weekdays = .everyday,
    enabled: Bool = true, action: ScheduleAction = ScheduleAction(power: true, mode: nil, manualLevel: nil)
) -> ScheduleRule {
    ScheduleRule(id: UUID(), isEnabled: enabled, hour: hour, minute: minute, weekdays: days, action: action)
}

/// Drives the machine into boost and supplies a confirmed Manual 14.
private func t4Boost(
    mode: PurifierMode = .auto, level: Int = 7, settings: ThresholdSettings = t4Threshold()
) -> (machine: ThresholdMachine, state: PurifierState, now: Date) {
    var machine = ThresholdMachine()
    let original = t4State(mode: mode, level: level)
    let first = machine.evaluate(state: original, settings: settings, now: t4Epoch)
    #expect(first.commands.isEmpty)
    #expect(first.recheckAt == t4Epoch.addingTimeInterval(settings.riseDuration))
    let now = t4Epoch.addingTimeInterval(settings.riseDuration)
    let boost = machine.evaluate(state: original, settings: settings, now: now)
    #expect(boost.commands == [.manualLevel(14)])
    var confirmed = original
    confirmed.mode = .manual
    confirmed.favoriteLevel = 14
    return (machine, confirmed, now)
}

@Suite("T4: pure threshold state machine")
struct T4ProbeThresholdTests {
    @Test("Default settings and initial phase")
    func defaults() {
        let settings = ThresholdSettings.standard
        #expect(settings.isEnabled)
        #expect(settings.pm25Limit == 35)
        #expect(settings.riseDuration == 120)
        #expect(settings.fallDuration == 600)
        #expect(AutomationSettings.standard.schedule.isEmpty)
        #expect(AutomationSettings.standard.threshold == settings)
        #expect(ThresholdMachine().phase == .idle)
    }

    @Test("Dirty air does not turn on a disabled device")
    func offNeverBoosts() {
        var machine = ThresholdMachine()
        for offset in [0.0, 120, 720, 86_400] {
            let result = machine.evaluate(state: t4State(pm25: 600, isOn: false), settings: t4Threshold(),
                                          now: t4Epoch.addingTimeInterval(offset))
            #expect(result.commands.isEmpty)
            #expect(result.recheckAt == nil)
            #expect(machine.phase == .idle)
        }
        let onAt = t4Epoch.addingTimeInterval(86_401)
        let result = machine.evaluate(state: t4State(), settings: t4Threshold(), now: onAt)
        #expect(machine.phase == .rising(since: onAt))
        #expect(result.recheckAt == onAt.addingTimeInterval(120))
    }

    @Test("N equal to the threshold does not start a boost", arguments: [0, 34, 35])
    func cleanIdle(pm25: Int) {
        var machine = ThresholdMachine()
        let result = machine.evaluate(state: t4State(pm25: pm25), settings: t4Threshold(), now: t4Epoch)
        #expect(result.commands.isEmpty)
        #expect(result.recheckAt == nil)
        #expect(machine.phase == .idle)
    }

    @Test("Boost only at the deadline; high probes do not move the start")
    func continuousRiseAndExactDeadline() {
        var machine = ThresholdMachine()
        let settings = t4Threshold()
        for offset in [0.0, 30, 119.999] {
            let result = machine.evaluate(state: t4State(pm25: 600), settings: settings,
                                          now: t4Epoch.addingTimeInterval(offset))
            #expect(result.commands.isEmpty)
            #expect(result.recheckAt == t4Epoch.addingTimeInterval(120))
            #expect(machine.phase == .rising(since: t4Epoch))
        }
        let result = machine.evaluate(state: t4State(), settings: settings, now: t4Epoch.addingTimeInterval(120))
        #expect(result.commands == [.manualLevel(14)])
        #expect(result.recheckAt == nil)
        #expect(machine.phase == .boosting(restore: .mode(.auto), level: 14, calmSince: nil))
    }

    @Test("Bounce near N resets the whole rise interval")
    func riseChatterResetsClock() {
        var machine = ThresholdMachine()
        let settings = t4Threshold()
        for start in [0.0, 100, 200] {
            let high = machine.evaluate(state: t4State(pm25: 36), settings: settings,
                                        now: t4Epoch.addingTimeInterval(start))
            #expect(high.commands.isEmpty)
            #expect(high.recheckAt == t4Epoch.addingTimeInterval(start + 120))
            let low = machine.evaluate(state: t4State(pm25: 35), settings: settings,
                                       now: t4Epoch.addingTimeInterval(start + 99))
            #expect(low.commands.isEmpty)
            #expect(low.recheckAt == nil)
            #expect(machine.phase == .idle)
        }
        _ = machine.evaluate(state: t4State(), settings: settings, now: t4Epoch.addingTimeInterval(300))
        #expect(machine.evaluate(state: t4State(), settings: settings,
                                 now: t4Epoch.addingTimeInterval(419.999)).commands.isEmpty)
        #expect(machine.evaluate(state: t4State(), settings: settings,
                                 now: t4Epoch.addingTimeInterval(420)).commands == [.manualLevel(14)])
    }

    @Test("Turning off during a rise resets the accumulated time")
    func powerOffDuringRise() {
        var machine = ThresholdMachine()
        let settings = t4Threshold()
        _ = machine.evaluate(state: t4State(), settings: settings, now: t4Epoch)
        let off = machine.evaluate(state: t4State(isOn: false), settings: settings,
                                   now: t4Epoch.addingTimeInterval(119))
        #expect(off.commands.isEmpty)
        #expect(off.recheckAt == nil)
        #expect(machine.phase == .idle)
        let on = machine.evaluate(state: t4State(), settings: settings, now: t4Epoch.addingTimeInterval(120))
        #expect(on.commands.isEmpty)
        #expect(on.recheckAt == t4Epoch.addingTimeInterval(240))
    }

    @Test("Restore Auto/Sleep and the exact Manual level", arguments: [PurifierMode.auto, .sleep, .manual])
    func restoresOriginalMode(mode: PurifierMode) {
        // Levels below boost: boost raises speed, and restore returns the exact
        // level. Manual with a level >= boost is not boosted (separate probe).
        for level in [0, 7] {
            var (machine, state, now) = t4Boost(mode: mode, level: level)
            let restore: PurifierCommand = mode == .manual ? .manualLevel(level) : .mode(mode)
            #expect(machine.phase == .boosting(restore: restore, level: 14, calmSince: nil))
            let dirty = machine.evaluate(state: state, settings: t4Threshold(), now: now.addingTimeInterval(1))
            #expect(dirty.commands.isEmpty)
            #expect(dirty.recheckAt == nil)
            state.pm25 = 35
            let calmAt = now.addingTimeInterval(10)
            let calm = machine.evaluate(state: state, settings: t4Threshold(), now: calmAt)
            #expect(calm.commands.isEmpty)
            #expect(calm.recheckAt == calmAt.addingTimeInterval(600))
            #expect(machine.phase == .boosting(restore: restore, level: 14, calmSince: calmAt))
            #expect(machine.evaluate(state: state, settings: t4Threshold(),
                                     now: calmAt.addingTimeInterval(599.999)).commands.isEmpty)
            let finish = machine.evaluate(state: state, settings: t4Threshold(), now: calmAt.addingTimeInterval(600))
            #expect(finish.commands == [restore])
            #expect(finish.recheckAt == nil)
            #expect(machine.phase == .idle)
            state.mode = mode
            state.favoriteLevel = level
            #expect(machine.evaluate(state: state, settings: t4Threshold(),
                                     now: calmAt.addingTimeInterval(601)).commands.isEmpty)
        }
    }

    @Test("Manual with a level not below the boost is not boosted")
    func manualAtBoostLevelDoesNotBoost() {
        // T12: boost does not lower speed, so Manual 14 stays as is.
        var machine = ThresholdMachine()
        _ = machine.evaluate(state: t4State(mode: .manual, level: 14), settings: t4Threshold(), now: t4Epoch)
        #expect(machine.phase == .rising(since: t4Epoch))
        let result = machine.evaluate(state: t4State(mode: .manual, level: 14), settings: t4Threshold(),
                                      now: t4Epoch.addingTimeInterval(120))
        #expect(result.commands.isEmpty)
        #expect(result.recheckAt == nil)
        #expect(machine.phase == .idle)
    }

    @Test("Restore keeps the mode at boost time, not at the first dirty probe")
    func snapshotsModeAtBoost() {
        var machine = ThresholdMachine()
        _ = machine.evaluate(state: t4State(mode: .auto), settings: t4Threshold(), now: t4Epoch)
        let result = machine.evaluate(state: t4State(mode: .manual, level: 3), settings: t4Threshold(),
                                      now: t4Epoch.addingTimeInterval(120))
        #expect(result.commands == [.manualLevel(14)])
        #expect(machine.phase == .boosting(restore: .manualLevel(3), level: 14, calmSince: nil))
    }

    @Test("Bounce during a boost resets the clean-air time")
    func fallChatterResetsClock() {
        var (machine, state, now) = t4Boost(mode: .sleep)
        state.pm25 = 35
        _ = machine.evaluate(state: state, settings: t4Threshold(), now: now)
        state.pm25 = 36
        let spike = machine.evaluate(state: state, settings: t4Threshold(), now: now.addingTimeInterval(599))
        #expect(spike.commands.isEmpty)
        #expect(spike.recheckAt == nil)
        #expect(machine.phase == .boosting(restore: .mode(.sleep), level: 14, calmSince: nil))
        state.pm25 = 34
        let calmAt = now.addingTimeInterval(600)
        _ = machine.evaluate(state: state, settings: t4Threshold(), now: calmAt)
        for offset in [1.0, 300, 599.999] {
            let calm = machine.evaluate(state: state, settings: t4Threshold(), now: calmAt.addingTimeInterval(offset))
            #expect(calm.commands.isEmpty)
            #expect(calm.recheckAt == calmAt.addingTimeInterval(600))
        }
        #expect(machine.evaluate(state: state, settings: t4Threshold(),
                                 now: calmAt.addingTimeInterval(600)).commands == [.mode(.sleep)])
    }

    @Test("External interference cancels the boost without restore", arguments: ["auto", "sleep", "level", "off"])
    func externalIntervention(kind: String) {
        var (machine, state, now) = t4Boost()
        state.pm25 = 35
        _ = machine.evaluate(state: state, settings: t4Threshold(), now: now)
        switch kind {
        case "auto": state.mode = .auto
        case "sleep": state.mode = .sleep
        case "level": state.favoriteLevel = 13
        default: state.isOn = false
        }
        let changed = machine.evaluate(state: state, settings: t4Threshold(), now: now.addingTimeInterval(600))
        #expect(changed.commands.isEmpty)
        #expect(changed.recheckAt == nil)
        #expect(machine.phase == .idle)
        #expect(machine.evaluate(state: state, settings: t4Threshold(),
                                 now: now.addingTimeInterval(1_200)).commands.isEmpty)
    }

    @Test("cancelBoost suppresses both the boost and an unfinished rise until clean air")
    func explicitCancellation() {
        var (machine, state, now) = t4Boost()
        machine.cancelBoost(state: state, settings: t4Threshold())
        machine.cancelBoost(state: state, settings: t4Threshold())
        #expect(machine.phase == .suppressed)
        state.pm25 = 35
        let result = machine.evaluate(state: state, settings: t4Threshold(), now: now.addingTimeInterval(600))
        #expect(result.commands.isEmpty)
        #expect(result.recheckAt == nil)
        #expect(machine.phase == .idle)
        state.pm25 = 36
        _ = machine.evaluate(state: state, settings: t4Threshold(), now: now.addingTimeInterval(601))
        #expect(machine.phase == .rising(since: now.addingTimeInterval(601)))
        machine.cancelBoost(state: state, settings: t4Threshold())
        let again = machine.evaluate(state: state, settings: t4Threshold(), now: now.addingTimeInterval(721))
        #expect(again.commands.isEmpty)
        #expect(again.recheckAt == nil)
        #expect(machine.phase == .suppressed)
    }

    @Test("Disabled and invalid settings", arguments: ["disabled", "limit", "riseZero", "riseNegative", "fallZero", "fallNegative"])
    func disabledAndInvalid(kind: String) {
        var settings = t4Threshold()
        switch kind {
        case "disabled": settings.isEnabled = false
        case "limit": settings.pm25Limit = -1
        case "riseZero": settings.riseDuration = 0
        case "riseNegative": settings.riseDuration = -1
        case "fallZero": settings.fallDuration = 0
        default: settings.fallDuration = -1
        }
        var idle = ThresholdMachine()
        let idleResult = idle.evaluate(state: t4State(), settings: settings, now: t4Epoch)
        #expect(idleResult.commands.isEmpty)
        #expect(idleResult.recheckAt == nil)
        #expect(idle.phase == .idle)
        var rising = ThresholdMachine()
        _ = rising.evaluate(state: t4State(), settings: t4Threshold(), now: t4Epoch)
        let riseResult = rising.evaluate(state: t4State(), settings: settings, now: t4Epoch.addingTimeInterval(120))
        #expect(riseResult.commands.isEmpty)
        #expect(riseResult.recheckAt == nil)
        #expect(rising.phase == .idle)
        var (boosting, state, now) = t4Boost(mode: .manual, level: 4)
        let boostResult = boosting.evaluate(state: state, settings: settings, now: now)
        #expect(boostResult.commands == [.manualLevel(4)])
        #expect(boostResult.recheckAt == nil)
        #expect(boosting.phase == .idle)
        #expect(boosting.evaluate(state: state, settings: settings, now: now.addingTimeInterval(1)).commands.isEmpty)
    }

    @Test("Zero N and fractional durations are not replaced by defaults")
    func customSettings() {
        let settings = t4Threshold(limit: 0, rise: 0.125, fall: 0.375)
        var (machine, state, now) = t4Boost(settings: settings)
        state.pm25 = 0
        let calm = machine.evaluate(state: state, settings: settings, now: now)
        #expect(calm.recheckAt == now.addingTimeInterval(0.375))
        #expect(machine.evaluate(state: state, settings: settings, now: now.addingTimeInterval(0.374)).commands.isEmpty)
        #expect(machine.evaluate(state: state, settings: settings,
                                 now: now.addingTimeInterval(0.375)).commands == [.mode(.auto)])
    }
}

@Suite("T4: calendar and schedule commands")
struct T4ProbeScheduleTests {
    @Test("Calendar.weekday: Sunday 1, Monday 2, all seven days")
    func weekdayMapping() {
        let days: [Weekdays] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        for (index, day) in days.enumerated() {
            for calendarDay in 1...7 {
                #expect(day.contains(calendarWeekday: calendarDay) == (calendarDay == index + 1))
                #expect(Weekdays.everyday.contains(calendarWeekday: calendarDay))
                #expect(!Weekdays(rawValue: 0).contains(calendarWeekday: calendarDay))
            }
        }
        #expect(days.reduce(Weekdays(rawValue: 0)) { $0.union($1) } == .everyday)
        let weekend: Weekdays = [.saturday, .sunday]
        #expect(weekend.contains(calendarWeekday: 1))
        #expect(weekend.contains(calendarWeekday: 7))
        #expect(!weekend.contains(calendarWeekday: 2))
    }

    @Test("Empty schedule, empty days and disabled rules")
    func inactiveRules() {
        let date = t4Date("2026-10-12T09:00:00Z")
        for rules in [[], [t4Rule(enabled: false)], [t4Rule(days: [])]] {
            #expect(Schedule.nextFire(after: date, rules: rules, calendar: t4Calendar()) == nil)
        }
    }

    @Test("Every weekday is found, including the next Sunday", arguments: Array(0..<7))
    func everyWeekday(offset: Int) throws {
        let days: [Weekdays] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        let rule = t4Rule(days: days[offset])
        let start = t4Date("2026-10-12T09:00:00Z")
        let result = try #require(Schedule.nextFire(after: start, rules: [rule], calendar: t4Calendar()))
        #expect(result.date == t4Date("2026-10-12T10:00:00Z").addingTimeInterval(Double(offset) * 86_400))
        #expect(result.rules == [rule])
    }

    @Test("Nearest rule from an unsorted list and skipping inactive ones")
    func earliestEnabledRule() throws {
        let later = t4Rule(hour: 18)
        let tomorrow = t4Rule(hour: 8)
        let earliest = t4Rule(hour: 11, minute: 7)
        let disabled = t4Rule(hour: 10, enabled: false)
        let wrongDay = t4Rule(hour: 10, days: .tuesday)
        let result = try #require(Schedule.nextFire(after: t4Date("2026-10-12T09:00:00Z"),
                                                   rules: [later, tomorrow, disabled, wrongDay, earliest], calendar: t4Calendar()))
        #expect(result.date == t4Date("2026-10-12T11:07:00Z"))
        #expect(result.rules == [earliest])
    }

    @Test("Strictly after: exact time and one second after it give the next week", arguments: [0.0, 1.0])
    func strictAfter(offset: TimeInterval) throws {
        let rule = t4Rule(days: .monday)
        let result = try #require(Schedule.nextFire(after: t4Date("2026-10-12T10:00:00Z").addingTimeInterval(offset),
                                                   rules: [rule], calendar: t4Calendar()))
        #expect(result.date == t4Date("2026-10-19T10:00:00Z"))
        #expect(result.rules == [rule])
    }

    @Test("Midnight, week and year transitions", arguments: [
        ["2026-10-16T23:59:59Z", "2026-10-17T00:00:00Z"],
        ["2026-10-18T23:59:59Z", "2026-10-19T00:00:00Z"],
        ["2026-12-31T23:59:59Z", "2027-01-01T00:00:00Z"]
    ])
    func midnight(pair: [String]) throws {
        let calendar = t4Calendar()
        let expected = t4Date(pair[1])
        let days: [Weekdays] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        let rule = t4Rule(hour: 0, days: days[calendar.component(.weekday, from: expected) - 1])
        let result = try #require(Schedule.nextFire(after: t4Date(pair[0]), rules: [rule], calendar: calendar))
        #expect(result.date == expected)
        #expect(result.rules == [rule])
    }

    @Test("All rules at the same time, each exactly once")
    func simultaneousRules() throws {
        let first = t4Rule(days: .monday)
        let second = t4Rule(action: ScheduleAction(power: nil, mode: .sleep, manualLevel: nil))
        let disabled = t4Rule(enabled: false)
        let otherDay = t4Rule(days: .tuesday)
        let result = try #require(Schedule.nextFire(after: t4Date("2026-10-12T09:59:59Z"),
                                                   rules: [second, disabled, first, otherDay], calendar: t4Calendar()))
        #expect(result.date == t4Date("2026-10-12T10:00:00Z"))
        #expect(result.rules.count == 2)
        #expect(Set(result.rules.map(\.id)) == Set([first.id, second.id]))
    }

    @Test("Events missed during sleep do not come back")
    func missedEventsAreNotCaughtUp() throws {
        let rule = t4Rule(days: [.monday, .wednesday])
        let result = try #require(Schedule.nextFire(after: t4Date("2026-10-14T10:00:01Z"),
                                                   rules: [rule], calendar: t4Calendar()))
        #expect(result.date == t4Date("2026-10-19T10:00:00Z"))
    }

    @Test("Europe/Kyiv: a DST day has 23 or 25 hours", arguments: [
        ["2026-03-28T10:00:00Z", "2026-03-29T09:00:00Z"],
        ["2026-10-24T09:00:00Z", "2026-10-25T10:00:00Z"]
    ])
    func daylightSavingWallTime(pair: [String]) throws {
        let calendar = t4Calendar("Europe/Kyiv")
        let rule = t4Rule(hour: 12)
        let start = t4Date(pair[0])
        let result = try #require(Schedule.nextFire(after: start, rules: [rule], calendar: calendar))
        #expect(result.date == t4Date(pair[1]))
        #expect(calendar.component(.hour, from: result.date) == 12)
        #expect(calendar.component(.minute, from: result.date) == 0)
        #expect(result.rules == [rule])
    }

    @Test("Repeated hour in autumn: both interpretations of the contract allowed")
    func repeatedDSTHour() throws {
        let rule = t4Rule(hour: 3, minute: 30, days: .sunday)
        let result = try #require(Schedule.nextFire(after: t4Date("2026-10-24T22:00:00Z"),
                                                   rules: [rule], calendar: t4Calendar("Europe/Kyiv")))
        let possible = [t4Date("2026-10-25T00:30:00Z"), t4Date("2026-10-25T01:30:00Z")]
        #expect(possible.contains(result.date))
        #expect(result.rules == [rule])
    }

    @Test("Non-existent hour in spring: the result is in the future and on an allowed day")
    func missingDSTHour() throws {
        // The contract does not define skipping or moving 03:30; we do not impose a Calendar policy.
        let calendar = t4Calendar("Europe/Kyiv")
        let start = t4Date("2026-03-28T22:00:00Z")
        let rule = t4Rule(hour: 3, minute: 30, days: .sunday)
        let result = try #require(Schedule.nextFire(after: start, rules: [rule], calendar: calendar))
        #expect(result.date > start)
        #expect(result.date <= t4Date("2026-04-05T00:30:00Z"))
        #expect(calendar.component(.weekday, from: result.date) == 1)
        #expect(result.rules == [rule])
    }

    @Test("Action commands: power-off dominates, Manual is written in one command")
    func actionCommands() {
        #expect(ScheduleAction(power: nil, mode: nil, manualLevel: nil).commands.isEmpty)
        #expect(ScheduleAction(power: false, mode: .manual, manualLevel: 14).commands == [.power(false)])
        let manualOn = ScheduleAction(power: true, mode: .manual, manualLevel: 0).commands
        #expect(manualOn.count == 2)
        #expect(manualOn.contains(.power(true)))
        #expect(manualOn.contains(.manualLevel(0)))
        #expect(ScheduleAction(power: nil, mode: .manual, manualLevel: 14).commands == [.manualLevel(14)])
        #expect(ScheduleAction(power: nil, mode: .manual, manualLevel: nil).commands == [.mode(.manual)])
        let sleepOn = ScheduleAction(power: true, mode: .sleep, manualLevel: nil).commands
        #expect(sleepOn.count == 2)
        #expect(sleepOn.contains(.power(true)))
        #expect(sleepOn.contains(.mode(.sleep)))
        #expect(ScheduleAction(power: nil, mode: .auto, manualLevel: nil).commands == [.mode(.auto)])
    }
}

@Suite("T4: settings storage")
struct T4ProbeSettingsTests {
    @Test("Missing and corrupted JSON give standard")
    func missingAndCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T4Probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("automation.json")
        let store = SettingsStore(url: url)
        #expect(store.load() == .standard)
        for bytes in [Data("{".utf8), Data("null".utf8), Data("{}".utf8)] {
            try bytes.write(to: url)
            #expect(store.load() == .standard)
        }
    }

    @Test("Round-trip of all fields and overwriting an existing file")
    func roundTripAndOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T4Probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("automation.json")
        let settings = t4Settings(threshold: t4Threshold(enabled: false, limit: 17, rise: 0.25, fall: 0.75), rules: [
            t4Rule(hour: 0, minute: 1, days: [.monday, .friday], enabled: false,
                   action: ScheduleAction(power: true, mode: .manual, manualLevel: 0)),
            t4Rule(hour: 23, minute: 59, days: .sunday,
                   action: ScheduleAction(power: false, mode: nil, manualLevel: nil))
        ])
        let store = SettingsStore(url: url)
        try store.save(settings)
        #expect(SettingsStore(url: url).load() == settings)
        let decoded = try JSONDecoder().decode(AutomationSettings.self, from: Data(contentsOf: url))
        #expect(decoded == settings)
        try store.save(.standard)
        #expect(SettingsStore(url: url).load() == .standard)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }
}

/// A controlled read-back pause that deliberately does not end just because the Task is cancelled.
private actor T4ProbeGate {
    private var released = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Fake without network; the log includes even the failed write attempts.
private actor T4ProbeDevice: PurifierDevice {
    enum Failure: Sendable { case transport, unconfirmed }
    struct Attempt: Sendable {
        let command: PurifierCommand
        let at: ContinuousClock.Instant
    }
    struct Snapshot: Sendable {
        let attempts: [Attempt]
        let reads: Int
        let activeReads: Int
        let state: PurifierState
        var commands: [PurifierCommand] { attempts.map(\.command) }
    }

    private var state: PurifierState
    private var attempts: [Attempt] = []
    private var reads = 0
    private var activeReads = 0
    private var failure: Failure?
    private var failureCommand: PurifierCommand?
    private var failuresRemaining = 0
    private var gatedCommand: PurifierCommand?
    private var gate: T4ProbeGate?
    private var nextReadGate: T4ProbeGate?

    init(_ state: PurifierState = t4State()) { self.state = state }

    func readState() async throws -> PurifierState {
        reads += 1
        activeReads += 1
        defer { activeReads -= 1 }
        if let readGate = nextReadGate {
            nextReadGate = nil
            await readGate.wait()
        }
        return state
    }

    func apply(_ command: PurifierCommand) async throws {
        attempts.append(Attempt(command: command, at: .now))
        if command == failureCommand, failuresRemaining > 0 {
            failuresRemaining -= 1
            if failure == .transport { throw MiIOError.timeout }
            return
        }
        // Own application of the command: we do not rely on the `applying` helper from T2.
        switch command {
        case .power(let value): state.isOn = value
        case .mode(let value): state.mode = value
        case .favoriteLevel(let value): state.favoriteLevel = value
        case .sound(let value): state.sound = value
        case .childLock(let value): state.childLock = value
        case .screen(let value): state.screen = value
        case .manualLevel(let value):
            state.mode = .manual
            state.favoriteLevel = value
        }
        if command == gatedCommand {
            nextReadGate = gate
            gatedCommand = nil
            gate = nil
        }
    }

    func replaceState(_ state: PurifierState) { self.state = state }
    func setPM25(_ value: Int) { state.pm25 = value }
    func fail(_ command: PurifierCommand, with failure: Failure, count: Int = 1) {
        failureCommand = command
        self.failure = failure
        failuresRemaining = count
    }
    func blockReadBack(after command: PurifierCommand, on gate: T4ProbeGate) {
        gatedCommand = command
        self.gate = gate
    }
    func snapshot() -> Snapshot {
        Snapshot(attempts: attempts, reads: reads, activeReads: activeReads, state: state)
    }
}

private final class T4ProbeClock: Sendable {
    private let origin = ContinuousClock.now
    private let base: Date
    private let offset = Mutex<TimeInterval>(0)

    init(date: Date) { base = date }

    private func elapsed() -> TimeInterval {
        let parts = origin.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func now() -> Date { base.addingTimeInterval(elapsed() + offset.withLock { $0 }) }

    func setDate(_ date: Date) {
        let newOffset = date.timeIntervalSince(base) - elapsed()
        offset.withLock { $0 = newOffset }
    }
}

@MainActor
private func t4Controller(_ device: T4ProbeDevice) -> PurifierController {
    PurifierController(device: device, policy: PollingPolicy(
        panelOpen: .seconds(60), panelClosed: .seconds(60),
        confirmAttempts: 2, confirmInterval: .milliseconds(5), failuresBeforeUnreachable: 2
    ))
}

@MainActor
private func t4Eventually(
    within timeout: Duration = .milliseconds(2_200),
    _ condition: @MainActor () async -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
private func t4SubscribeAndPublish(_ engine: AutomationEngine, _ controller: PurifierController) async throws {
    engine.start()
    // Give the subscription task time to register the stream before the first confirmed state.
    try await Task.sleep(for: .milliseconds(20))
    await controller.refreshNow()
}

@Suite("T4: engine with a fake device", .serialized)
@MainActor
struct T4ProbeEngineTests {
    @Test("Deadlines run boost/restore without new probes and without polling")
    func deadlinesWithoutNewSamples() async throws {
        let device = T4ProbeDevice(t4State(mode: .manual, level: 3))
        let controller = t4Controller(device)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.12, fall: 0.18)))
        defer { engine.stop(); controller.stop() }
        let riseStarted = ContinuousClock.now
        try await t4SubscribeAndPublish(engine, controller)
        engine.start()
        try #require(await t4Eventually { await device.snapshot().attempts.count >= 1 })
        let boosted = await device.snapshot()
        #expect(boosted.commands == [.manualLevel(14)])
        let boostDelay = riseStarted.duration(to: boosted.attempts[0].at)
        #expect(boostDelay >= .milliseconds(100) && boostDelay <= .milliseconds(2_200))
        try #require(await t4Eventually { engine.isBoosting })
        #expect(controller.state?.mode == .manual)
        #expect(controller.state?.favoriteLevel == 14)
        let calmStarted = ContinuousClock.now
        await device.setPM25(35)
        await controller.refreshNow()
        try #require(await t4Eventually { await device.snapshot().attempts.count >= 2 })
        let restored = await device.snapshot()
        #expect(restored.commands == [.manualLevel(14), .manualLevel(3)])
        let restoreDelay = calmStarted.duration(to: restored.attempts[1].at)
        #expect(restoreDelay >= .milliseconds(160) && restoreDelay <= .milliseconds(2_200))
        try #require(await t4Eventually { !engine.isBoosting })
        #expect(controller.state?.favoriteLevel == 3)
        // Only two explicit refreshes and two read-backs. The controller did not run its own loop.
        #expect(restored.reads == 4)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await device.snapshot().reads == restored.reads)
        #expect(await device.snapshot().commands == restored.commands)
    }

    @Test("A disabled purifier is not boosted; turning it on starts a new rise")
    func poweredOffDevice() async throws {
        let device = T4ProbeDevice(t4State(isOn: false))
        let controller = t4Controller(device)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.12, fall: 0.15)))
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(await device.snapshot().commands.isEmpty)
        #expect(!engine.isBoosting)
        let enabledAt = ContinuousClock.now
        await device.replaceState(t4State())
        await controller.refreshNow()
        try #require(await t4Eventually { await device.snapshot().attempts.count >= 1 })
        let snapshot = await device.snapshot()
        #expect(snapshot.commands == [.manualLevel(14)])
        let delay = enabledAt.duration(to: snapshot.attempts[0].at)
        #expect(delay >= .milliseconds(100) && delay <= .milliseconds(2_200))
    }

    @Test("A manual command has priority and cancels restore permanently", arguments: [
        PurifierCommand.mode(.sleep), .manualLevel(4), .power(false)   // non-fan commands: nonFanCommandsKeepBoostAndRise
    ])
    func userCommandCancelsRestore(command: PurifierCommand) async throws {
        let device = T4ProbeDevice()
        let controller = t4Controller(device)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.08, fall: 0.12)))
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually { engine.isBoosting })
        // PM changes before the read-back of the manual action; we do not let a legitimate rise start.
        await device.setPM25(35)
        try await engine.userSend(command)
        try #require(await t4Eventually { !engine.isBoosting })
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(await device.snapshot().commands == [.manualLevel(14), command])
    }

    @Test("External interference arrives through stateUpdates", arguments: ["mode", "level", "off"])
    func externalStateCancelsRestore(kind: String) async throws {
        let device = T4ProbeDevice()
        let controller = t4Controller(device)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.08, fall: 0.12)))
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually { engine.isBoosting })
        var state = t4State(pm25: 35, mode: .manual, level: 14)
        switch kind {
        case "mode": state.mode = .sleep
        case "level": state.favoriteLevel = 13
        default: state.isOn = false
        }
        await device.replaceState(state)
        await controller.refreshNow()
        try #require(await t4Eventually { !engine.isBoosting })
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(await device.snapshot().commands == [.manualLevel(14)])
        #expect(controller.state == state)
    }

    @Test("Changing settings turns off the threshold and restores the previous mode")
    func settingsReplanAndRestore() async throws {
        let device = T4ProbeDevice(t4State(mode: .sleep))
        let controller = t4Controller(device)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.08, fall: 0.12)))
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually { engine.isBoosting })
        var settings = engine.settings
        settings.threshold.isEnabled = false
        engine.settings = settings
        try #require(await t4Eventually { await device.snapshot().attempts.count >= 2 && !engine.isBoosting })
        #expect(await device.snapshot().commands == [.manualLevel(14), .mode(.sleep)])
    }

    @Test("A failed boost does not change the phase and is not retried more often than 30 s", arguments: [
        T4ProbeDevice.Failure.transport, .unconfirmed
    ])
    fileprivate func failedBoostBackoff(failure: T4ProbeDevice.Failure) async throws {
        let device = T4ProbeDevice()
        await device.fail(.manualLevel(14), with: failure)
        let controller = t4Controller(device)
        let offset = Mutex<TimeInterval>(0)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.08, fall: 0.12)),
                                      now: { Date().addingTimeInterval(offset.withLock { $0 }) })
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually { await device.snapshot().attempts.count == 1 })
        try #require(await t4Eventually { controller.pending == nil })
        #expect(!engine.isBoosting)
        for pm25 in [37, 38, 39] {
            await device.setPM25(pm25)
            await controller.refreshNow()
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(await device.snapshot().commands == [.manualLevel(14)])
        #expect(!engine.isBoosting)
        // New synthetic time allows a retry without 30 real seconds of sleep.
        offset.withLock { $0 = 31 }
        engine.reschedule()
        await device.setPM25(40)
        await controller.refreshNow()
        try #require(await t4Eventually { engine.isBoosting })
        #expect(await device.snapshot().commands == [.manualLevel(14), .manualLevel(14)])
    }

    @Test("A failed restore keeps the boost active and is retried after backoff")
    func failedRestoreBackoff() async throws {
        let device = T4ProbeDevice()
        let controller = t4Controller(device)
        let offset = Mutex<TimeInterval>(0)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.08, fall: 0.12)),
                                      now: { Date().addingTimeInterval(offset.withLock { $0 }) })
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually { engine.isBoosting })
        await device.fail(.mode(.auto), with: .transport)
        await device.setPM25(35)
        await controller.refreshNow()
        try #require(await t4Eventually { await device.snapshot().attempts.count >= 2 })
        #expect(engine.isBoosting)
        #expect(controller.state?.mode == .manual)
        await device.setPM25(34)
        await controller.refreshNow()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await device.snapshot().commands == [.manualLevel(14), .mode(.auto)])
        offset.withLock { $0 = 31 }
        engine.reschedule()
        await device.setPM25(33)
        await controller.refreshNow()
        try #require(await t4Eventually { !engine.isBoosting })
        #expect(await device.snapshot().commands == [.manualLevel(14), .mode(.auto), .mode(.auto)])
    }

    @Test("The schedule cancels the boost and runs action.commands in turn")
    func scheduleOverridesBoost() async throws {
        let device = T4ProbeDevice()
        let controller = t4Controller(device)
        let clock = T4ProbeClock(date: t4Date("2026-10-12T09:59:50Z"))
        let action = ScheduleAction(power: false, mode: .sleep, manualLevel: nil)
        let rule = t4Rule(action: action)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.08, fall: 0.12), rules: [rule]),
                                      calendar: t4Calendar(), now: { clock.now() })
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually { engine.isBoosting })
        let scheduleStarted = ContinuousClock.now
        clock.setDate(t4Date("2026-10-12T09:59:59Z").addingTimeInterval(0.75))
        engine.reschedule()
        // The schedule allows tolerance up to 5 s, the threshold up to 1 s.
        try #require(await t4Eventually(within: .milliseconds(6_500)) {
            await device.snapshot().commands.contains(.power(false))
        })
        try #require(await t4Eventually { !engine.isBoosting })
        let snapshot = await device.snapshot()
        #expect(snapshot.commands == [.manualLevel(14)] + action.commands)
        let scheduleAt = try #require(snapshot.attempts.first { $0.command == .power(false) }).at
        let delay = scheduleStarted.duration(to: scheduleAt)
        #expect(delay >= .milliseconds(230) && delay <= .milliseconds(6_500))
        await device.setPM25(35)
        await controller.refreshNow()
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(await device.snapshot().commands == snapshot.commands)
        #expect(controller.state?.isOn == false)
    }

    @Test("A rule error does not stop the next rule at the same time")
    func scheduleErrorDoesNotStopEngine() async throws {
        let device = T4ProbeDevice(t4State(pm25: 10))
        let controller = t4Controller(device)
        let clock = T4ProbeClock(date: t4Date("2026-10-12T09:59:59Z").addingTimeInterval(0.75))
        await device.fail(.mode(.sleep), with: .transport)
        let failing = t4Rule(action: ScheduleAction(power: nil, mode: .sleep, manualLevel: nil))
        let succeeding = t4Rule(action: ScheduleAction(power: nil, mode: .manual, manualLevel: 4))
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(enabled: false), rules: [failing, succeeding]),
                                      calendar: t4Calendar(), now: { clock.now() })
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually(within: .milliseconds(6_500)) { await device.snapshot().attempts.count >= 2 })
        let commands = await device.snapshot().commands
        #expect(commands.count == 2)
        #expect(commands.contains(.mode(.sleep)))
        #expect(commands.contains(.manualLevel(4)))
        try await engine.userSend(.sound(true))
        #expect(await device.snapshot().commands.last == .sound(true))
    }

    @Test("stop cancels the deadline, the subscription and rescheduling", arguments: [false, true])
    func stopCancelsThresholdWork(calm: Bool) async throws {
        let device = T4ProbeDevice()
        let controller = t4Controller(device)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.15, fall: 0.15)))
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        if calm {
            try #require(await t4Eventually { engine.isBoosting })
            await device.setPM25(35)
            await controller.refreshNow()
        }
        try await Task.sleep(for: .milliseconds(30))
        engine.stop()
        engine.stop()
        let stopped = await device.snapshot()
        engine.reschedule()
        var settings = engine.settings
        settings.threshold.riseDuration = 0.01
        settings.threshold.fallDuration = 0.01
        engine.settings = settings
        await device.setPM25(calm ? 34 : 100)
        await controller.refreshNow()
        try await Task.sleep(for: .milliseconds(1_400))
        #expect(await device.snapshot().commands == stopped.commands)
        // The only extra read is the explicit refresh, performed by the test itself.
        #expect(await device.snapshot().reads == stopped.reads + 1)
        #expect(await device.snapshot().activeReads == 0)
    }

    @Test("stop before the schedule cancels the future command")
    func stopCancelsScheduleDeadline() async throws {
        let device = T4ProbeDevice(t4State(pm25: 10))
        let controller = t4Controller(device)
        let clock = T4ProbeClock(date: t4Date("2026-10-12T09:59:59Z").addingTimeInterval(0.75))
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(enabled: false), rules: [t4Rule()]),
                                      calendar: t4Calendar(), now: { clock.now() })
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        engine.stop()
        try await Task.sleep(for: .milliseconds(5_500))
        #expect(await device.snapshot().commands.isEmpty)
        #expect(await device.snapshot().reads == 1)
    }

    @Test("stop during the schedule's read-back does not allow a second schedule command")
    func stopDuringScheduleReadBack() async throws {
        let device = T4ProbeDevice(t4State(pm25: 10, isOn: false))
        let controller = t4Controller(device)
        let gate = T4ProbeGate()
        let action = ScheduleAction(power: true, mode: .manual, manualLevel: 4)
        let firstCommand = try #require(action.commands.first)
        #expect(action.commands.count == 2)
        await device.blockReadBack(after: firstCommand, on: gate)
        let clock = T4ProbeClock(date: t4Date("2026-10-12T09:59:59Z").addingTimeInterval(0.75))
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(enabled: false), rules: [t4Rule(action: action)]),
                                      calendar: t4Calendar(), now: { clock.now() })
        defer {
            engine.stop()
            controller.stop()
            Task { await gate.release() }
        }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually(within: .milliseconds(6_500)) { await gate.hasEntered() })
        #expect(await device.snapshot().commands == [firstCommand])
        engine.stop()
        await gate.release()
        try #require(await t4Eventually { await device.snapshot().activeReads == 0 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await device.snapshot().commands == [firstCommand])
        let reads = await device.snapshot().reads
        try await Task.sleep(for: .milliseconds(300))
        #expect(await device.snapshot().reads == reads)
    }

    @Test("stop during the boost's read-back does not create a new restore deadline")
    func stopDuringBoostReadBack() async throws {
        let device = T4ProbeDevice()
        let controller = t4Controller(device)
        let gate = T4ProbeGate()
        await device.blockReadBack(after: .manualLevel(14), on: gate)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.08, fall: 0.12)))
        defer {
            engine.stop()
            controller.stop()
            Task { await gate.release() }
        }
        try await t4SubscribeAndPublish(engine, controller)
        try #require(await t4Eventually { await gate.hasEntered() })
        engine.stop()
        await device.setPM25(35)
        await gate.release()
        try #require(await t4Eventually { await device.snapshot().activeReads == 0 })
        let stopped = await device.snapshot()
        try await Task.sleep(for: .milliseconds(1_400))
        #expect(await device.snapshot().commands == [.manualLevel(14)])
        #expect(await device.snapshot().reads == stopped.reads)
    }

    @Test("reschedule after sleep skips the past rule and cancels the old sleep")
    func wakeDoesNotCatchUpMissedRule() async throws {
        let device = T4ProbeDevice(t4State(pm25: 10))
        let controller = t4Controller(device)
        let clock = T4ProbeClock(date: t4Date("2026-10-12T09:59:59Z").addingTimeInterval(0.75))
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(enabled: false), rules: [t4Rule(days: .monday)]),
                                      calendar: t4Calendar(), now: { clock.now() })
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        clock.setDate(t4Date("2026-10-12T10:00:01Z"))
        engine.reschedule()
        try await Task.sleep(for: .milliseconds(5_500))
        #expect(await device.snapshot().commands.isEmpty)
        #expect(await device.snapshot().reads == 1)
    }

    @Test("start after stop restores exactly one subscription and one deadline")
    func restartHasOneSubscription() async throws {
        let device = T4ProbeDevice(t4State(pm25: 10))
        let controller = t4Controller(device)
        let engine = AutomationEngine(controller: controller,
                                      settings: t4Settings(threshold: t4Threshold(rise: 0.12, fall: 0.15)))
        defer { engine.stop(); controller.stop() }
        try await t4SubscribeAndPublish(engine, controller)
        engine.stop()
        engine.start()
        engine.start()
        try await Task.sleep(for: .milliseconds(20))
        await device.setPM25(40)
        await controller.refreshNow()
        try #require(await t4Eventually { engine.isBoosting })
        try await Task.sleep(for: .milliseconds(250))
        #expect(await device.snapshot().commands == [.manualLevel(14)])
    }
}
