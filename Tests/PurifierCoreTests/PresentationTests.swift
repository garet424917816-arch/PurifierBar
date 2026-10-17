// Presentation tests: PM2.5 levels, color blending and panel lines.
import Foundation
import Testing
@testable import PurifierCore

// MARK: - AirQuality

@Test func airQualityBoundaries() {
    #expect(AirQuality(pm25: 0) == .excellent)
    #expect(AirQuality(pm25: 15) == .excellent)
    #expect(AirQuality(pm25: 16) == .good)
    #expect(AirQuality(pm25: 35) == .good)
    #expect(AirQuality(pm25: 36) == .moderate)
    #expect(AirQuality(pm25: 75) == .moderate)
    #expect(AirQuality(pm25: 76) == .poor)
    #expect(AirQuality(pm25: 115) == .poor)
    #expect(AirQuality(pm25: 116) == .unhealthy)
    #expect(AirQuality(pm25: 150) == .unhealthy)
    #expect(AirQuality(pm25: 151) == .hazardous)
    #expect(AirQuality(pm25: 600) == .hazardous)
}

@Test func airQualityMonotonicThroughAllCases() {
    // Every level is reachable by its representative and not confused with its neighbor.
    let representatives = [7, 20, 50, 90, 130, 200]
    #expect(representatives.map { AirQuality(pm25: $0) } == AirQuality.allCases)
}

@Test func airQualityTitles() {
    #expect(AirQuality.excellent.title == "Excellent")
    #expect(AirQuality.good.title == "Good")
    #expect(AirQuality.moderate.title == "Moderate")
    #expect(AirQuality.poor.title == "Poor")
    #expect(AirQuality.unhealthy.title == "Unhealthy")
    #expect(AirQuality.hazardous.title == "Hazardous")
}

@Test func airQualityColorsInRangeAndDistinct() {
    var seen: [(r: Double, g: Double, b: Double)] = []
    for quality in AirQuality.allCases {
        let rgb = quality.rgb
        #expect((0...1).contains(rgb.r))
        #expect((0...1).contains(rgb.g))
        #expect((0...1).contains(rgb.b))
        #expect(!seen.contains { $0 == rgb })
        seen.append(rgb)
    }
}

@Test func airQualityColorProgressesGreenToRed() {
    // From "Excellent" to "Hazardous" green falls, red rises:
    // green -> yellow -> orange -> red -> purple.
    #expect(AirQuality.excellent.rgb.g > AirQuality.excellent.rgb.r)
    #expect(AirQuality.poor.rgb.r > AirQuality.poor.rgb.g)
    #expect(AirQuality.unhealthy.rgb.r > AirQuality.unhealthy.rgb.g)
    #expect(AirQuality.excellent.rgb.g > AirQuality.hazardous.rgb.g)
    #expect(AirQuality.hazardous.rgb.b > AirQuality.hazardous.rgb.g)
}

// MARK: - blendRGB

@Test func blendRGBEndpoints() {
    let a = (r: 0.0, g: 0.2, b: 0.4)
    let b = (r: 1.0, g: 0.6, b: 0.0)

    let atZero = blendRGB(a, b, 0)
    #expect(atZero == a)
    let atOne = blendRGB(a, b, 1)
    #expect(atOne == b)
}

@Test func blendRGBMidpoint() {
    let mixed = blendRGB((r: 0, g: 0, b: 0), (r: 1, g: 0.5, b: 0.2), 0.5)
    #expect(abs(mixed.r - 0.5) < 1e-12)
    #expect(abs(mixed.g - 0.25) < 1e-12)
    #expect(abs(mixed.b - 0.1) < 1e-12)
}

@Test func blendRGBClampsT() {
    let a = (r: 0.1, g: 0.1, b: 0.1)
    let b = (r: 0.9, g: 0.9, b: 0.9)
    #expect(blendRGB(a, b, -3) == a)
    #expect(blendRGB(a, b, 7) == b)
    let half = blendRGB(a, b, 0.5)
    #expect(abs(half.r - 0.5) < 1e-12)
}

// MARK: - PanelFormat

@Test func menuBarTitleStates() {
    #expect(PanelFormat.menuBarTitle(pm25: 18, connection: .online) == "18")
    #expect(PanelFormat.menuBarTitle(pm25: 18, connection: .connecting) == "18")
    #expect(PanelFormat.menuBarTitle(pm25: 18, connection: .unreachable) == "18?")
    #expect(PanelFormat.menuBarTitle(pm25: nil, connection: .connecting) == "—")
    #expect(PanelFormat.menuBarTitle(pm25: nil, connection: .unreachable) == "—")
}

@Test func filterText() {
    #expect(PanelFormat.filter(percent: 64, daysLeft: 186) == "64 % · 186 d")
}

@Test func modeText() {
    #expect(PanelFormat.mode(.auto) == "Auto")
    #expect(PanelFormat.mode(.sleep) == "Sleep")
    #expect(PanelFormat.mode(.manual) == "Manual")
}

@Test func screenText() {
    #expect(PanelFormat.screen(.off) == "Off")
    #expect(PanelFormat.screen(.bright) == "Bright")
    #expect(PanelFormat.screen(.dim) == "Dim")
}

@Test func faultText() {
    #expect(PanelFormat.fault(.none) == nil)
    #expect(PanelFormat.fault(.motorStuck) == "Motor stuck")
    #expect(PanelFormat.fault(.sensorLost) == "Sensor lost")
    #expect(PanelFormat.fault(.other(7)) == "Error 7")
}

// MARK: - PanelFormat: schedule

/// Fixed calendar: explicit time zone and first day of week (Monday).
private func scheduleCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
    calendar.firstWeekday = 2
    return calendar
}

@Test func scheduleWeekdaysSummary() {
    #expect(PanelFormat.scheduleWeekdays(.everyday) == "Every day")
    #expect(PanelFormat.scheduleWeekdays(PanelFormat.weekdays) == "Weekdays")
    #expect(PanelFormat.scheduleWeekdays(PanelFormat.weekends) == "Weekends")
    #expect(PanelFormat.scheduleWeekdays([]) == "No days")
    #expect(PanelFormat.scheduleWeekdays([.monday, .wednesday, .friday]) == "Mon Wed Fri")
    #expect(PanelFormat.scheduleWeekdays([.sunday]) == "Sun")
    // Order is always Mon..Sun, regardless of the order of days in the set.
    #expect(PanelFormat.scheduleWeekdays([.sunday, .saturday, .monday]) == "Mon Sat Sun")
    #expect(PanelFormat.scheduleWeekdays(PanelFormat.weekdays.union(PanelFormat.weekends)) == "Every day")
}

@Test func scheduleActionSummary() {
    #expect(PanelFormat.scheduleAction(ScheduleAction()) == "No change")
    #expect(PanelFormat.scheduleAction(ScheduleAction(power: true)) == "On")
    #expect(PanelFormat.scheduleAction(ScheduleAction(power: false)) == "Off")
    #expect(PanelFormat.scheduleAction(ScheduleAction(power: true, mode: .sleep)) == "On · Sleep")
    #expect(PanelFormat.scheduleAction(ScheduleAction(mode: .auto)) == "Auto")
    #expect(PanelFormat.scheduleAction(ScheduleAction(mode: .sleep)) == "Sleep")
    #expect(PanelFormat.scheduleAction(ScheduleAction(mode: .manual, manualLevel: 7)) == "Manual 7")
    #expect(PanelFormat.scheduleAction(ScheduleAction(mode: .manual)) == "Manual")
    // A level outside manual mode is not shown.
    #expect(PanelFormat.scheduleAction(ScheduleAction(mode: .sleep, manualLevel: 5)) == "Sleep")
}

@Test func scheduleTimeFormatting() {
    #expect(PanelFormat.scheduleTime(hour: 7, minute: 5) == "07:05")
    #expect(PanelFormat.scheduleTime(hour: 0, minute: 0) == "00:00")
    #expect(PanelFormat.scheduleTime(hour: 12, minute: 30) == "12:30")
    #expect(PanelFormat.scheduleTime(hour: 23, minute: 59) == "23:59")
}

@Test func scheduleNextToday() {
    let calendar = scheduleCalendar()
    let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8, minute: 0))!
    let rule = ScheduleRule(hour: 9, minute: 30, weekdays: .everyday)
    #expect(PanelFormat.scheduleNext(after: now, rules: [rule], calendar: calendar) == "today 09:30")
}

@Test func scheduleNextTomorrow() {
    let calendar = scheduleCalendar()
    // 2026-06-15, 23:00 (Monday): the 07:00 rule fires on the next day.
    let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 23, minute: 0))!
    let rule = ScheduleRule(hour: 7, minute: 0, weekdays: .everyday)
    #expect(PanelFormat.scheduleNext(after: now, rules: [rule], calendar: calendar) == "tomorrow 07:00")
}

@Test func scheduleNextLaterWeekday() {
    let calendar = scheduleCalendar()
    let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8, minute: 0))!
    // 2026-06-15 is a Monday; the nearest Friday is 2026-06-19.
    #expect(calendar.component(.weekday, from: now) == 2)
    let rule = ScheduleRule(hour: 9, minute: 0, weekdays: [.friday])
    #expect(PanelFormat.scheduleNext(after: now, rules: [rule], calendar: calendar) == "Fri 09:00")
}

@Test func scheduleNextNilWithoutEnabledRules() {
    let calendar = scheduleCalendar()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(PanelFormat.scheduleNext(after: now, rules: [], calendar: calendar) == nil)
    let disabled = ScheduleRule(isEnabled: false, hour: 9, minute: 0, weekdays: .everyday)
    #expect(PanelFormat.scheduleNext(after: now, rules: [disabled], calendar: calendar) == nil)
}

@Test func filterWithoutDaysShowsOnlyPercent() {
    #expect(PanelFormat.filter(percent: 64, daysLeft: nil) == "64 %")
    #expect(PanelFormat.filter(percent: 0, daysLeft: nil) == "0 %")
}
