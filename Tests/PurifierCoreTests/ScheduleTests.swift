// Tests of weekdays, actions and finding the nearest schedule trigger.
import Foundation
import Testing
@testable import PurifierCore

// MARK: - Weekdays

@Test func weekdayMapsToCalendarWeekday() {
    #expect(Weekdays.sunday.contains(calendarWeekday: 1))
    #expect(Weekdays.monday.contains(calendarWeekday: 2))
    #expect(Weekdays.saturday.contains(calendarWeekday: 7))
    #expect(!Weekdays.monday.contains(calendarWeekday: 1))
    #expect(!Weekdays.sunday.contains(calendarWeekday: 7))
}

@Test func everydayContainsAllWeekdays() {
    for weekday in 1...7 {
        #expect(Weekdays.everyday.contains(calendarWeekday: weekday))
    }
    #expect(!Weekdays.everyday.contains(calendarWeekday: 0))
    #expect(!Weekdays.everyday.contains(calendarWeekday: 8))
}

@Test func combinedWeekdaysContainEachMember() {
    let weekdays: Weekdays = [.monday, .wednesday, .friday]
    #expect(weekdays.contains(calendarWeekday: 2))
    #expect(weekdays.contains(calendarWeekday: 4))
    #expect(weekdays.contains(calendarWeekday: 6))
    #expect(!weekdays.contains(calendarWeekday: 3))
}

// MARK: - ScheduleAction.commands

@Test func actionCommandsForPowerOffIsSelfContained() {
    let action = ScheduleAction(power: false, mode: .manual, manualLevel: 14)
    #expect(action.commands == [.power(false)])
}

@Test func actionCommandsForManualLevel() {
    let action = ScheduleAction(mode: .manual, manualLevel: 14)
    #expect(action.commands == [.manualLevel(14)])
}

@Test func actionCommandsForPowerOnAndMode() {
    let action = ScheduleAction(power: true, mode: .sleep)
    #expect(action.commands == [.power(true), .mode(.sleep)])
}

@Test func actionCommandsEmptyAndManualWithoutLevel() {
    #expect(ScheduleAction().commands.isEmpty)
    #expect(ScheduleAction(mode: .manual).commands == [.mode(.manual)])
    // A level without mode manual makes no sense.
    #expect(ScheduleAction(manualLevel: 14).commands.isEmpty)
    #expect(ScheduleAction(power: false, manualLevel: 5).commands == [.power(false)])
}

// MARK: - nextFire

@Test func nextFireFindsSameDayOccurrence() {
    let calendar = kyivCalendar()
    let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8, minute: 0))!
    let rule = ScheduleRule(hour: 9, minute: 30, weekdays: .everyday, action: ScheduleAction(power: false))

    let fire = Schedule.nextFire(after: date, rules: [rule], calendar: calendar)
    let expected = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9, minute: 30))!
    #expect(fire?.date == expected)
    #expect(fire?.rules.map(\.id) == [rule.id])
}

@Test func nextFireCrossesMidnight() {
    let calendar = kyivCalendar()
    let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23, minute: 55))!
    let rule = ScheduleRule(hour: 23, minute: 50, weekdays: .everyday)

    let fire = Schedule.nextFire(after: date, rules: [rule], calendar: calendar)
    let expected = calendar.date(from: DateComponents(year: 2026, month: 6, day: 16, hour: 23, minute: 50))!
    #expect(fire?.date == expected)
}

@Test func nextFireIsStrictlyAfterDate() {
    let calendar = kyivCalendar()
    let exactly = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9, minute: 30))!
    let rule = ScheduleRule(hour: 9, minute: 30, weekdays: .everyday)

    let fire = Schedule.nextFire(after: exactly, rules: [rule], calendar: calendar)
    let expected = calendar.date(from: DateComponents(year: 2026, month: 6, day: 16, hour: 9, minute: 30))!
    #expect(fire?.date == expected)
}

@Test func nextFireCrossesWeek() {
    let calendar = kyivCalendar()
    // 2026-06-17 is a Wednesday; the nearest Monday is 2026-06-22.
    let wednesday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12, minute: 0))!
    #expect(calendar.component(.weekday, from: wednesday) == 4)
    let rule = ScheduleRule(hour: 9, minute: 0, weekdays: .monday)

    let fire = Schedule.nextFire(after: wednesday, rules: [rule], calendar: calendar)
    let expected = calendar.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 9, minute: 0))!
    #expect(fire?.date == expected)
}

@Test func nextFireReturnsAllRulesAtTheSameMoment() {
    let calendar = kyivCalendar()
    let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8, minute: 0))!
    let first = ScheduleRule(hour: 9, minute: 0, weekdays: .everyday, action: ScheduleAction(power: false))
    let second = ScheduleRule(hour: 9, minute: 0, weekdays: .everyday, action: ScheduleAction(mode: .sleep))
    let third = ScheduleRule(hour: 10, minute: 0, weekdays: .everyday, action: ScheduleAction(mode: .auto))

    let fire = Schedule.nextFire(after: date, rules: [first, second, third], calendar: calendar)
    #expect(fire?.rules.map(\.id) == [first.id, second.id])
}

@Test func nextFireSkipsDisabledRules() {
    let calendar = kyivCalendar()
    let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8, minute: 0))!
    let disabled = ScheduleRule(isEnabled: false, hour: 8, minute: 30, weekdays: .everyday)
    let enabled = ScheduleRule(hour: 9, minute: 0, weekdays: .everyday)

    let fire = Schedule.nextFire(after: date, rules: [disabled, enabled], calendar: calendar)
    let expected = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9, minute: 0))!
    #expect(fire?.date == expected)
    #expect(fire?.rules.map(\.id) == [enabled.id])
}

@Test func nextFireWithoutEnabledRulesIsNil() {
    let calendar = kyivCalendar()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(Schedule.nextFire(after: date, rules: [], calendar: calendar) == nil)
    let disabled = ScheduleRule(isEnabled: false, hour: 9, minute: 0, weekdays: .everyday)
    #expect(Schedule.nextFire(after: date, rules: [disabled], calendar: calendar) == nil)
    let noWeekdays = ScheduleRule(hour: 9, minute: 0, weekdays: [])
    #expect(Schedule.nextFire(after: date, rules: [noWeekdays], calendar: calendar) == nil)
}

// MARK: - daylight saving time transition

@Test func nextFireHandlesSpringForward() {
    let calendar = kyivCalendar()
    // 2026-03-29 at 03:00 Kyiv time is moved forward to 04:00.
    let before = calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 12, minute: 0))!
    let rule = ScheduleRule(hour: 9, minute: 0, weekdays: .everyday)

    let first = Schedule.nextFire(after: before, rules: [rule], calendar: calendar)!
    let firstComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: first.date)
    #expect(firstComponents.day == 29)
    #expect(firstComponents.hour == 9)
    #expect(firstComponents.minute == 0)
    // The transition day is an hour shorter: 12:00 -> 09:00 next day = 20 hours.
    #expect(first.date.timeIntervalSince(before) == 20 * 3600)

    let second = Schedule.nextFire(after: first.date, rules: [rule], calendar: calendar)!
    #expect(second.date.timeIntervalSince(first.date) == 24 * 3600)
    #expect(calendar.component(.day, from: second.date) == 30)
}

@Test func nextFireHandlesFallBack() {
    let calendar = kyivCalendar()
    // 2026-10-25 at 04:00 Kyiv time is moved back to 03:00.
    let before = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 12, minute: 0))!
    let rule = ScheduleRule(hour: 9, minute: 0, weekdays: .everyday)

    let first = Schedule.nextFire(after: before, rules: [rule], calendar: calendar)!
    // The transition day is an hour longer: 12:00 -> 09:00 next day = 22 hours.
    #expect(first.date.timeIntervalSince(before) == 22 * 3600)
    let firstComponents = calendar.dateComponents([.day, .hour], from: first.date)
    #expect(firstComponents.day == 25)
    #expect(firstComponents.hour == 9)

    let second = Schedule.nextFire(after: first.date, rules: [rule], calendar: calendar)!
    #expect(second.date.timeIntervalSince(first.date) == 24 * 3600)
}
