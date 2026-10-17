// Engine tests on a fake device and short durations (milliseconds).
import Foundation
import Testing
@testable import PurifierCore

private func thresholdSettings(
    rise: TimeInterval = 0.05,
    fall: TimeInterval = 0.05,
    limit: Int = 35
) -> ThresholdSettings {
    ThresholdSettings(isEnabled: true, pm25Limit: limit, riseDuration: rise, fallDuration: fall)
}

// MARK: - Threshold

@MainActor
@Test func engineBoostsAndRestores() async {
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [], threshold: thresholdSettings())
    )

    controller.start()
    await waitFor("online") { controller.connection == .online }
    engine.start()

    await waitFor("boost") { engine.isBoosting }
    #expect(await device.applied.contains(.manualLevel(14)))

    // The air cleared - after fallDuration the restore to Auto must arrive.
    await device.setState(automationState(mode: .manual, pm25: 10, favoriteLevel: 14))
    await waitFor("restore") { await device.applied.contains(.mode(.auto)) }
    await waitFor("boost cleared") { !engine.isBoosting }

    engine.stop()
    controller.stop()
}

@MainActor
@Test func externalInterferenceCancelsBoostWithoutRestore() async {
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [], threshold: thresholdSettings(rise: 0.02, fall: 5))
    )

    controller.start()
    await waitFor("online") { controller.connection == .online }
    engine.start()
    await waitFor("boost") { engine.isBoosting }

    // Someone switched the device to Auto past us - boost cancelled, no restore.
    await device.setState(automationState(mode: .auto, pm25: 5))
    await waitFor("cancelled") { !engine.isBoosting }
    #expect(!(await device.applied.contains(.mode(.auto))))

    engine.stop()
    controller.stop()
}

@MainActor
@Test(arguments: [PurifierCommand.mode(.sleep), .manualLevel(4), .power(false)])
func userSendCancelsBoost(command: PurifierCommand) async throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let clock = AutomationClock(start)
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [], threshold: thresholdSettings(rise: 60)),
        now: { clock.now }
    )
    defer { engine.stop(); controller.stop() }
    await controller.refreshNow()
    await engine.reconcile()
    clock.set(start.addingTimeInterval(60))
    await engine.reconcile()
    #expect(engine.isBoosting)
    #expect(await device.applied == [.manualLevel(14)])

    try await engine.userSend(command)
    #expect(!engine.isBoosting)
    #expect(engine.machine.phase == .suppressed)
    for offset: TimeInterval in [61, 120, 180, 600] {
        clock.set(start.addingTimeInterval(offset))
        await engine.reconcile()
        #expect(engine.machine.phase == .suppressed)
        #expect(!engine.isBoosting)
        #expect(engine.commandBackoffUntil == nil)
        #expect(await device.applied == [.manualLevel(14), command])
    }

    var state = try #require(controller.state)
    state.pm25 = 35
    await device.setState(state)
    await controller.refreshNow()
    await engine.reconcile()
    #expect(engine.machine.phase == .idle)
    #expect(await device.applied == [.manualLevel(14), command])

    // Fresh pollution starts a full rise; turning on or lowering speed allows a boost.
    state = automationState(mode: .sleep, pm25: 80)
    await device.setState(state)
    await controller.refreshNow()
    let riseAt = start.addingTimeInterval(601)
    clock.set(riseAt)
    await engine.reconcile()
    #expect(engine.machine.phase == .rising(since: riseAt))
    clock.set(riseAt.addingTimeInterval(59))
    await engine.reconcile()
    #expect(await device.applied == [.manualLevel(14), command])
    clock.set(riseAt.addingTimeInterval(60))
    await engine.reconcile()
    #expect(engine.isBoosting)
    #expect(await device.applied == [.manualLevel(14), command, .manualLevel(14)])
}

@MainActor
@Test(arguments: [PurifierCommand.sound(true), .childLock(true), .screen(.dim)])
func nonFanCommandsKeepBoostAndRise(command: PurifierCommand) async throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let clock = AutomationClock(start)
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [], threshold: thresholdSettings(rise: 60)),
        now: { clock.now }
    )
    defer { engine.stop(); controller.stop() }
    await controller.refreshNow()
    await engine.reconcile()
    #expect(engine.machine.phase == .rising(since: start))

    // During the rise: the countdown is not restarted.
    try await engine.userSend(command)
    #expect(engine.machine.phase == .rising(since: start))
    clock.set(start.addingTimeInterval(60))
    await engine.reconcile()
    #expect(engine.isBoosting)
    #expect(await device.applied == [command, .manualLevel(14)])

    // During the boost: it continues.
    try await engine.userSend(command)
    #expect(engine.isBoosting)
    clock.set(start.addingTimeInterval(120))
    await engine.reconcile()
    #expect(engine.isBoosting)
    #expect(await device.applied == [command, .manualLevel(14), command])
}

@Test func onlyFanCommandsControlTheBoost() {
    #expect(AutomationEngine.controlsFan(.power(true)))
    #expect(AutomationEngine.controlsFan(.mode(.auto)))
    #expect(AutomationEngine.controlsFan(.manualLevel(3)))
    #expect(AutomationEngine.controlsFan(.favoriteLevel(3)))
    #expect(!AutomationEngine.controlsFan(.sound(false)))
    #expect(!AutomationEngine.controlsFan(.childLock(false)))
    #expect(!AutomationEngine.controlsFan(.screen(.off)))
}

@MainActor
@Test func failingBoostKeepsPhaseAndBacksOff() async {
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    await device.setAppliesCommands(false)   // write not confirmed
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [], threshold: thresholdSettings(rise: 0.02))
    )

    controller.start()
    await waitFor("online") { controller.connection == .online }
    engine.start()

    await waitFor("boost attempt") { await device.applied.contains(.manualLevel(14)) }
    try? await Task.sleep(for: .milliseconds(120))   // read-back did not confirm, the phase rolled back
    #expect(!engine.isBoosting)   // phase did not change
    let attempts = await device.applied.count

    try? await Task.sleep(for: .milliseconds(150))
    let later = await device.applied.count
    #expect(later == attempts)    // retry not earlier than in 30 s

    engine.stop()
    controller.stop()
}

@MainActor
@Test func invalidThresholdNeverBoosts() async {
    let device = AutomationFakeDevice(state: automationState(pm25: 200))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(
            schedule: [],
            threshold: ThresholdSettings(isEnabled: true, pm25Limit: -1, riseDuration: 0.01, fallDuration: 0.01)
        )
    )

    controller.start()
    await waitFor("online") { controller.connection == .online }
    engine.start()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(!engine.isBoosting)
    #expect(await device.applied.isEmpty)

    engine.stop()
    controller.stop()
}

// MARK: - Schedule

@MainActor
@Test(arguments: [false, true])
func scheduleRuleFiresAndCancelsBoost(power: Bool) async throws {
    let calendar = kyivCalendar()
    let start = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 6, day: 15, hour: 12, minute: 0, second: 30
    )))
    let clock = AutomationClock(start)
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let action = ScheduleAction(power: power, mode: .sleep)
    let rule = ScheduleRule(hour: 12, minute: 1, weekdays: .everyday, action: action)
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [rule], threshold: thresholdSettings(rise: 10)),
        calendar: calendar, now: { clock.now }
    )
    defer { engine.stop(); controller.stop() }
    await controller.refreshNow()
    await engine.reconcile()
    clock.set(start.addingTimeInterval(10))
    await engine.reconcile()
    #expect(engine.isBoosting)

    clock.set(start.addingTimeInterval(35))
    await engine.reconcile()
    #expect(!engine.isBoosting)
    #expect(engine.machine.phase == .suppressed)
    #expect(controller.state?.isOn == power)
    #expect(controller.state?.mode == (power ? .sleep : .manual))
    for offset: TimeInterval in [45, 60, 600] {
        clock.set(start.addingTimeInterval(offset))
        await engine.reconcile()
        #expect(engine.machine.phase == .suppressed)
        #expect(!engine.isBoosting)
        #expect(await device.applied == [.manualLevel(14)] + action.commands)
    }
}

@MainActor
@Test func missedScheduleRuleIsNotCaughtUp() async {
    let calendar = kyivCalendar()
    let start = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12, minute: 0, second: 30))!
    let clock = AutomationClock(start)
    let weekday = calendar.component(.weekday, from: start)

    let device = AutomationFakeDevice(state: automationState(pm25: 5))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let rule = ScheduleRule(
        hour: 12, minute: 1,
        weekdays: Weekdays(rawValue: 1 << (weekday - 1)),
        action: ScheduleAction(power: false)
    )
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [rule], threshold: ThresholdSettings(isEnabled: false)),
        calendar: calendar,
        now: { clock.now }
    )

    controller.start()
    await waitFor("online") { controller.connection == .online }
    engine.start()

    // The Mac "slept" and woke up after the rule's time - the trigger was missed.
    clock.set(calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12, minute: 30))!)
    engine.reschedule()
    await device.setState(automationState(pm25: 7))   // an extra nudge

    try? await Task.sleep(for: .milliseconds(100))
    #expect(await device.applied.isEmpty)

    engine.stop()
    controller.stop()
}

@MainActor
@Test func stopLeavesNoLiveWork() async {
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [], threshold: thresholdSettings(rise: 0.02))
    )

    controller.start()
    await waitFor("online") { controller.connection == .online }
    engine.start()
    await waitFor("boost") { engine.isBoosting }
    engine.stop()

    // After stop, even a clean-air event must not trigger a restore.
    let countAfterStop = await device.applied.count
    await device.setState(automationState(mode: .manual, pm25: 10, favoriteLevel: 14))
    try? await Task.sleep(for: .milliseconds(80))
    let later = await device.applied.count
    #expect(later == countAfterStop)

    controller.stop()
}

@MainActor
@Test(arguments: [PurifierLayout.mb5, .proH])
func engineClampsBoostAndConfirmsIt(layout: PurifierLayout) async {
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [], threshold: thresholdSettings()),
        favoriteLevelRange: layout.favoriteLevelRange
    )
    defer {
        engine.stop()
        controller.stop()
    }
    controller.start()
    await waitFor("online") { controller.connection == .online }
    engine.start()
    let maximum = layout.favoriteLevelRange.upperBound
    await waitFor("confirmed device boost") {
        controller.state?.mode == .manual && controller.state?.favoriteLevel == maximum && engine.isBoosting
    }
    #expect(engine.isBoosting)
    #expect(await device.applied == [.manualLevel(maximum)])
    #expect(engine.settings.threshold.boostLevel == 14)
    await device.setState(automationState(mode: .manual, pm25: 10, favoriteLevel: maximum))
    await waitFor("restore after clamped boost") { await device.applied.contains(.mode(.auto)) }
    await waitFor("boost cleared") { !engine.isBoosting }
}

// MARK: - Superseded automation commands

@MainActor
@Test func userCommandSupersedesInFlightBoostWithoutRollbackOrBackoff() async throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let clock = AutomationClock(start)
    let device = AutomationFakeDevice(state: automationState(pm25: 80))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [], threshold: thresholdSettings(rise: 60)),
        now: { clock.now }
    )
    defer { engine.stop(); controller.stop() }
    await controller.refreshNow()
    await engine.reconcile()
    #expect(engine.machine.phase == .rising(since: start))
    clock.set(start.addingTimeInterval(60))

    let gate = CommandTestGate()
    defer { Task { await gate.release() } }
    await device.enqueueRead(gate: gate)
    let boost = Task { await engine.reconcile() }
    await gate.waitUntilEntered()
    #expect(engine.isBoosting)
    try await engine.userSend(.mode(.sleep))
    #expect(engine.machine.phase == .suppressed)
    await gate.release()
    await boost.value

    #expect(engine.machine.phase == .suppressed)
    #expect(!engine.isBoosting)
    #expect(engine.commandBackoffUntil == nil)
    #expect(controller.state?.mode == .sleep)
    #expect(await device.applied == [.manualLevel(14), .mode(.sleep)])

    // Same dirty air stays suppressed even beyond the displaced boost's rise duration.
    await engine.reconcile()
    #expect(engine.machine.phase == .suppressed)
    clock.set(start.addingTimeInterval(181))
    await engine.reconcile()
    #expect(engine.machine.phase == .suppressed)
    #expect(!engine.isBoosting)
    #expect(engine.commandBackoffUntil == nil)
    #expect(await device.applied == [.manualLevel(14), .mode(.sleep)])
}

@MainActor
@Test func supersededScheduleDoesNotSendRemainingCommands() async throws {
    let calendar = kyivCalendar()
    let start = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 6, day: 15, hour: 12, minute: 0, second: 30
    )))
    let clock = AutomationClock(start)
    let device = AutomationFakeDevice(state: automationState(pm25: 10))
    let controller = PurifierController(device: device, policy: automationPolicy())
    let rule = ScheduleRule(
        hour: 12, minute: 1, weekdays: .everyday,
        action: ScheduleAction(power: true, mode: .manual, manualLevel: 9)
    )
    let engine = AutomationEngine(
        controller: controller,
        settings: AutomationSettings(schedule: [rule], threshold: thresholdSettings(rise: 60)),
        calendar: calendar, now: { clock.now }
    )
    defer { engine.stop(); controller.stop() }
    await controller.refreshNow()
    await engine.reconcile()
    clock.set(start.addingTimeInterval(31))
    let gate = CommandTestGate()
    defer { Task { await gate.release() } }
    await device.enqueueRead(gate: gate)
    let scheduled = Task { await engine.reconcile() }
    await gate.waitUntilEntered()
    try await engine.userSend(.mode(.sleep))
    await gate.release()
    await scheduled.value
    await engine.reconcile()
    #expect(engine.machine.phase == .idle)
    #expect(!engine.isBoosting)
    #expect(engine.commandBackoffUntil == nil)
    #expect(controller.state?.mode == .sleep)
    #expect(await device.applied == [.power(true), .mode(.sleep)])
}
