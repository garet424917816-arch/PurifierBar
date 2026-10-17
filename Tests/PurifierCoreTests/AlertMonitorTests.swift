// Tests of the notification monitor: synthetic time as a parameter, no waits and no timers.
import Foundation
import Testing
@testable import PurifierCore

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func at(_ seconds: TimeInterval) -> Date {
    t0.addingTimeInterval(seconds)
}

private func state(
    fault: PurifierFault = .none,
    filterPercent: Int = 100,
    pm25: Int = 10
) -> PurifierState {
    PurifierState(
        isOn: true,
        fault: fault,
        mode: .auto,
        pm25: pm25,
        filterPercent: filterPercent,
        filterHoursUsed: 0,
        filterDaysLeft: 90,
        sound: false,
        childLock: false,
        screen: .bright,
        motorRPM: 0,
        favoriteLevel: 0
    )
}

private func settings(
    filterLow: Bool = true,
    fault: Bool = true,
    unreachable: Bool = true,
    minutes: Int = 10
) -> AlertSettings {
    AlertSettings(
        filterLow: filterLow,
        fault: fault,
        unreachable: unreachable,
        unreachableMinutes: minutes
    )
}

// MARK: - Filter

@Test func filterAlertsOnceUntilReplaced() {
    var monitor = AlertMonitor(settings: settings())

    #expect(monitor.observe(state: state(filterPercent: 5), connection: .online, now: at(0))
        == [.filterLow(percent: 5)])
    // The same low life - silence.
    #expect(monitor.observe(state: state(filterPercent: 5), connection: .online, now: at(60)) == [])
    #expect(monitor.memory.filterLowNotified)
    // Between thresholds the flag is not reset.
    #expect(monitor.observe(state: state(filterPercent: 40), connection: .online, now: at(120)) == [])
    #expect(monitor.memory.filterLowNotified)
    // Life is >= 50 % again - the filter is replaced, the flag is reset.
    #expect(monitor.observe(state: state(filterPercent: 60), connection: .online, now: at(180)) == [])
    #expect(!monitor.memory.filterLowNotified)
    // Low life again - a new notification.
    #expect(monitor.observe(state: state(filterPercent: 3), connection: .online, now: at(240))
        == [.filterLow(percent: 3)])
}

@Test func filterThresholdBoundaryIsStrict() {
    var monitor = AlertMonitor(settings: settings())
    #expect(monitor.observe(state: state(filterPercent: 10), connection: .online, now: at(0)) == [])
    #expect(!monitor.memory.filterLowNotified)
    #expect(monitor.observe(state: state(filterPercent: 9), connection: .online, now: at(1))
        == [.filterLow(percent: 9)])
}

@Test func filterNeedsFreshState() {
    var monitor = AlertMonitor(settings: settings())
    // State is there, but no connectivity - we do not evaluate.
    #expect(monitor.observe(state: state(filterPercent: 1), connection: .unreachable, now: at(0)) == [])
    #expect(monitor.observe(state: state(filterPercent: 1), connection: .connecting, now: at(1)) == [])
    #expect(!monitor.memory.filterLowNotified)
    // No fresh state - we do not evaluate either.
    #expect(monitor.observe(state: nil, connection: .online, now: at(2)) == [])
    #expect(!monitor.memory.filterLowNotified)
    // Online with state - we evaluate.
    #expect(monitor.observe(state: state(filterPercent: 1), connection: .online, now: at(3))
        == [.filterLow(percent: 1)])
}

@Test func filterDisabledDoesNotAlertOrTouchMemory() {
    var monitor = AlertMonitor(settings: settings(filterLow: false))
    #expect(monitor.observe(state: state(filterPercent: 2), connection: .online, now: at(0)) == [])
    #expect(!monitor.memory.filterLowNotified)
    // Even replacing the filter does not change the memory while the toggle is off.
    #expect(monitor.observe(state: state(filterPercent: 90), connection: .online, now: at(1)) == [])
    #expect(!monitor.memory.filterLowNotified)

    // Turned on - low life notifies at the nearest observe.
    monitor.settings.filterLow = true
    #expect(monitor.observe(state: state(filterPercent: 2), connection: .online, now: at(2))
        == [.filterLow(percent: 2)])
}

@Test func filterMemoryKeptWhenDisabledAfterAlert() {
    var monitor = AlertMonitor(settings: settings())
    #expect(monitor.observe(state: state(filterPercent: 4), connection: .online, now: at(0))
        == [.filterLow(percent: 4)])
    monitor.settings.filterLow = false
    // A disabled toggle does not reset the memory even after a replacement.
    #expect(monitor.observe(state: state(filterPercent: 90), connection: .online, now: at(1)) == [])
    #expect(monitor.memory.filterLowNotified)
}

// MARK: - Malfunction

@Test func faultAlertsOnlyOnNewFault() {
    var monitor = AlertMonitor(settings: settings())

    #expect(monitor.observe(state: state(fault: .none), connection: .online, now: at(0)) == [])
    #expect(monitor.observe(state: state(fault: .motorStuck), connection: .online, now: at(1))
        == [.fault(.motorStuck)])
    // The same malfunction continues - silence.
    #expect(monitor.observe(state: state(fault: .motorStuck), connection: .online, now: at(2)) == [])
    // Gone - silence.
    #expect(monitor.observe(state: state(fault: .none), connection: .online, now: at(3)) == [])
    // Came back - a new notification.
    #expect(monitor.observe(state: state(fault: .motorStuck), connection: .online, now: at(4))
        == [.fault(.motorStuck)])
    // A different malfunction - also a new notification.
    #expect(monitor.observe(state: state(fault: .sensorLost), connection: .online, now: at(5))
        == [.fault(.sensorLost)])
}

@Test func faultOtherCodeAlerts() {
    var monitor = AlertMonitor(settings: settings())
    #expect(monitor.observe(state: state(fault: .other(7)), connection: .online, now: at(0))
        == [.fault(.other(7))])
}

@Test func faultNeedsFreshState() {
    var monitor = AlertMonitor(settings: settings())
    #expect(monitor.observe(state: state(fault: .motorStuck), connection: .unreachable, now: at(0)) == [])
    #expect(monitor.observe(state: nil, connection: .online, now: at(1)) == [])
}

@Test func faultTrackingContinuesWhileDisabled() {
    var monitor = AlertMonitor(settings: settings(fault: false))
    // A malfunction appeared while the toggle was off - silence, but it was remembered.
    #expect(monitor.observe(state: state(fault: .motorStuck), connection: .online, now: at(0)) == [])
    monitor.settings.fault = true
    // Turning on in the middle of a malfunction does not notify.
    #expect(monitor.observe(state: state(fault: .motorStuck), connection: .online, now: at(1)) == [])
    // Gone and came back - now it notifies.
    #expect(monitor.observe(state: state(fault: .none), connection: .online, now: at(2)) == [])
    #expect(monitor.observe(state: state(fault: .motorStuck), connection: .online, now: at(3))
        == [.fault(.motorStuck)])
}

// MARK: - Unavailability

@Test func unreachableAlertsOncePerEpisode() {
    var monitor = AlertMonitor(settings: settings(minutes: 10))

    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(0)) == [])
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(599)) == [])
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(600))
        == [.unreachable(since: at(0))])
    // One episode - one notification.
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(1200)) == [])

    // Back online - the episode is over.
    #expect(monitor.observe(state: state(), connection: .online, now: at(1300)) == [])
    // New episode - a new notification from the new start.
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(2000)) == [])
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(2600))
        == [.unreachable(since: at(2000))])
}

@Test func connectingDoesNotStartOrEndEpisode() {
    var monitor = AlertMonitor(settings: settings(minutes: 10))

    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(0)) == [])
    // `.connecting` neither ends an episode nor starts a new one.
    #expect(monitor.observe(state: nil, connection: .connecting, now: at(300)) == [])
    #expect(monitor.nextDeadline() == at(600))
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(600))
        == [.unreachable(since: at(0))])
}

@Test func connectingAloneNeverAlerts() {
    var monitor = AlertMonitor(settings: settings(minutes: 1))
    #expect(monitor.observe(state: nil, connection: .connecting, now: at(0)) == [])
    #expect(monitor.observe(state: nil, connection: .connecting, now: at(3600)) == [])
    #expect(monitor.nextDeadline() == nil)
}

@Test func unreachableDisabledThenEnabledAlertsLate() {
    var monitor = AlertMonitor(settings: settings(unreachable: false, minutes: 10))
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(0)) == [])
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(600)) == [])
    #expect(monitor.nextDeadline() == nil)

    // Turned on in the middle of an episode, the time has already passed - we notify at the nearest observe.
    monitor.settings.unreachable = true
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(601))
        == [.unreachable(since: at(0))])
}

@Test func unreachableDisabledEndsEpisodeOnOnline() {
    var monitor = AlertMonitor(settings: settings(unreachable: false, minutes: 10))
    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(0)) == [])
    #expect(monitor.observe(state: state(), connection: .online, now: at(60)) == [])
    monitor.settings.unreachable = true
    // The episode ended even though the toggle was off - we do not catch up with the old one.
    #expect(monitor.observe(state: state(), connection: .online, now: at(700)) == [])
    #expect(monitor.nextDeadline() == nil)
}

@Test func unreachableMinutesClamped() {
    // 0 minutes is clamped to 1.
    var low = AlertMonitor(settings: settings(minutes: 0))
    #expect(low.observe(state: nil, connection: .unreachable, now: at(0)) == [])
    #expect(low.observe(state: nil, connection: .unreachable, now: at(59)) == [])
    #expect(low.observe(state: nil, connection: .unreachable, now: at(60))
        == [.unreachable(since: at(0))])

    // 1000 minutes is clamped to 240.
    var high = AlertMonitor(settings: settings(minutes: 1000))
    #expect(high.observe(state: nil, connection: .unreachable, now: at(0)) == [])
    #expect(high.nextDeadline() == at(240 * 60))
}

@Test func unreachableOnlyForUnreachableConnection() {
    var monitor = AlertMonitor(settings: settings(minutes: 10))
    #expect(monitor.observe(state: nil, connection: .online, now: at(0)) == [])
    #expect(monitor.observe(state: nil, connection: .online, now: at(10_000)) == [])
    #expect(monitor.nextDeadline() == nil)
}

// MARK: - Order and deadline

@Test func resultOrderIsFaultBeforeFilterLow() {
    var monitor = AlertMonitor(settings: settings())
    let alerts = monitor.observe(
        state: state(fault: .motorStuck, filterPercent: 4),
        connection: .online,
        now: at(0)
    )
    #expect(alerts == [.fault(.motorStuck), .filterLow(percent: 4)])
}

@Test func nextDeadlineNilWithoutEpisodeOrAfterNotifying() {
    var monitor = AlertMonitor(settings: settings(minutes: 10))
    #expect(monitor.nextDeadline() == nil)

    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(0)) == [])
    #expect(monitor.nextDeadline() == at(600))

    #expect(monitor.observe(state: nil, connection: .unreachable, now: at(600))
        == [.unreachable(since: at(0))])
    #expect(monitor.nextDeadline() == nil)

    #expect(monitor.observe(state: state(), connection: .online, now: at(700)) == [])
    #expect(monitor.nextDeadline() == nil)
}

// MARK: - Memory

@Test func memoryCodableRoundTrip() throws {
    let memory = AlertMemory(filterLowNotified: true)
    let data = try JSONEncoder().encode(memory)
    #expect(try JSONDecoder().decode(AlertMemory.self, from: data) == memory)
    #expect(AlertMemory() == AlertMemory(filterLowNotified: false))
}
