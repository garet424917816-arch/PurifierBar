// Controller tests on a fake device. Intervals are in milliseconds,
// no waits of seconds.
import Foundation
import Synchronization
import Testing
@testable import PurifierCore

/// Fake device: controlled delays, errors, command application.
actor FakeDevice: PurifierDevice {
    var state: PurifierState
    var readDelay: Duration = .zero
    var applyDelay: Duration = .zero
    /// Whether `apply` changes internal state; false - the device "did not apply".
    var appliesCommands = true
    var applyError: MiIOError?
    private var readErrorsRemaining = 0
    private(set) var readCount = 0
    private(set) var applied: [PurifierCommand] = []

    init(state: PurifierState) { self.state = state }

    func readState() async throws -> PurifierState {
        readCount += 1
        if readDelay > .zero { try? await Task.sleep(for: readDelay) }
        if readErrorsRemaining > 0 {
            readErrorsRemaining -= 1
            throw MiIOError.timeout
        }
        return state
    }

    func apply(_ command: PurifierCommand) async throws {
        if applyDelay > .zero { try? await Task.sleep(for: applyDelay) }
        if let applyError { throw applyError }
        applied.append(command)
        if appliesCommands { state = state.applying(command) }
    }

    func setReadErrors(_ count: Int) { readErrorsRemaining = count }
    func setState(_ newState: PurifierState) { state = newState }
    func setAppliesCommands(_ flag: Bool) { appliesCommands = flag }
    func setApplyError(_ error: MiIOError?) { applyError = error }
    func setApplyDelay(_ duration: Duration) { applyDelay = duration }
    func setReadDelay(_ duration: Duration) { readDelay = duration }
}

private let baseState = PurifierState(
    isOn: true,
    fault: .none,
    mode: .auto,
    pm25: 18,
    filterPercent: 64,
    filterHoursUsed: 100,
    filterDaysLeft: 186,
    sound: false,
    childLock: false,
    screen: .bright,
    motorRPM: 416,
    favoriteLevel: 9
)

private func fastPolicy(
    panelOpen: Duration = .milliseconds(5),
    panelClosed: Duration = .milliseconds(5),
    confirmAttempts: Int = 5,
    confirmInterval: Duration = .milliseconds(2),
    failuresBeforeUnreachable: Int = 2
) -> PollingPolicy {
    PollingPolicy(
        panelOpen: panelOpen,
        panelClosed: panelClosed,
        confirmAttempts: confirmAttempts,
        confirmInterval: confirmInterval,
        failuresBeforeUnreachable: failuresBeforeUnreachable
    )
}

/// Waits for a condition with a timeout, without long sleeps.
@MainActor
private func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timeout waiting for: \(what)")
}

@MainActor
private func expectSendError<E: Error & Equatable>(
    _ controller: PurifierController,
    _ command: PurifierCommand,
    _ expected: E
) async {
    do {
        try await controller.send(command)
        Issue.record("expected error \(expected), but send succeeded")
    } catch let error as E {
        #expect(error == expected)
    } catch {
        Issue.record("different error type: \(error)")
    }
}

// MARK: - Polling loop

@MainActor
@Test func pollsAndPublishesState() async {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())

    #expect(controller.connection == .connecting)
    #expect(controller.state == nil)

    controller.start()
    await waitUntil("online") { controller.connection == .online }
    #expect(controller.state == baseState)
    controller.stop()
}

@MainActor
@Test func startIsIdempotentAndStopStops() async {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy(panelClosed: .milliseconds(5)))

    controller.start()
    controller.start()   // repeated call - no effect
    await waitUntil("online") { controller.connection == .online }
    controller.stop()

    try? await Task.sleep(for: .milliseconds(20))
    let afterStop = await device.readCount
    try? await Task.sleep(for: .milliseconds(40))
    let later = await device.readCount
    #expect(later == afterStop)
}

@MainActor
@Test func panelOpenPollsImmediatelyAndFaster() async {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(
        device: device,
        policy: fastPolicy(panelOpen: .milliseconds(5), panelClosed: .seconds(5))
    )

    controller.start()
    await waitUntil("first poll") { await device.readCount >= 1 }
    try? await Task.sleep(for: .milliseconds(30))
    let closedReads = await device.readCount
    #expect(closedReads == 1)   // panel closed: the next poll comes only after 5 s

    controller.isPanelOpen = true
    await waitUntil("immediate poll on open") { await device.readCount > closedReads }

    let openStart = await device.readCount
    try? await Task.sleep(for: .milliseconds(60))
    let openReads = await device.readCount
    #expect(openReads >= openStart + 3)   // panel open: interval 5 ms
    controller.stop()
}

@MainActor
@Test func unreachableKeepsStateAndRecovers() async {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(
        device: device,
        policy: fastPolicy(panelClosed: .milliseconds(10), failuresBeforeUnreachable: 2)
    )

    controller.start()
    await waitUntil("online") { controller.connection == .online }

    await device.setReadErrors(10)
    await waitUntil("unreachable") { controller.connection == .unreachable }
    #expect(controller.state == baseState)   // state is not erased

    await waitUntil("recovery") { controller.connection == .online }
    #expect(controller.state == baseState)
    controller.stop()
}

@MainActor
@Test func refreshNowPollsImmediately() async {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy(panelClosed: .seconds(30)))

    controller.start()
    await waitUntil("online") { controller.connection == .online }
    let before = await device.readCount

    await controller.refreshNow()
    let after = await device.readCount
    #expect(after > before)
    #expect(controller.state == baseState)
    controller.stop()
}

// MARK: - Commands

@MainActor
@Test func sendConfirmsViaReadBack() async throws {
    let device = FakeDevice(state: baseState)   // isOn == true
    let controller = PurifierController(device: device, policy: fastPolicy())
    controller.start()
    await waitUntil("online") { controller.connection == .online }

    try await controller.send(.power(false))
    #expect(controller.state?.isOn == false)
    #expect(controller.pending == nil)
    #expect(await device.applied == [.power(false)])
    controller.stop()
}

@MainActor
@Test func sendManualLevelWritesModeAndLevel() async throws {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())

    try await controller.send(.manualLevel(14))
    #expect(controller.state?.mode == .manual)
    #expect(controller.state?.favoriteLevel == 14)
    #expect(await device.applied == [.manualLevel(14)])
}

@MainActor
@Test func sendThrowsWhenNotApplied() async {
    let device = FakeDevice(state: baseState)
    await device.setAppliesCommands(false)
    let controller = PurifierController(
        device: device,
        policy: fastPolicy(confirmAttempts: 3, confirmInterval: .milliseconds(2))
    )

    await expectSendError(controller, .power(false), DeviceError.notConfirmed)
    #expect(controller.pending == nil)
    #expect(controller.state == baseState)   // last read state
}

@MainActor
@Test func sendPropagatesApplyError() async {
    let device = FakeDevice(state: baseState)
    await device.setApplyError(.timeout)
    let controller = PurifierController(device: device, policy: fastPolicy())

    await expectSendError(controller, .power(false), MiIOError.timeout)
    #expect(controller.pending == nil)
    #expect(await device.readCount == 0)   // read-back did not run
}

@MainActor
@Test func sendRejectsInvalidLevelWithoutNetwork() async {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())

    await expectSendError(controller, .favoriteLevel(15), DeviceError.invalidValue)
    #expect(controller.pending == nil)
    #expect(await device.applied.isEmpty)
    #expect(await device.readCount == 0)
}

@MainActor
@Test func pollDuringSendDoesNotOverwriteState() async {
    let device = FakeDevice(state: baseState)   // pm25 == 18, sound == false
    await device.setApplyDelay(.milliseconds(120))
    let controller = PurifierController(
        device: device,
        policy: fastPolicy(panelOpen: .milliseconds(5), panelClosed: .milliseconds(5),
                           confirmAttempts: 5, confirmInterval: .milliseconds(50))
    )
    controller.start()
    await waitUntil("initial state") { controller.state == baseState }

    let sendTask = Task { try? await controller.send(.sound(true)) }
    await waitUntil("pending set") { controller.pending == .sound(true) }

    // While apply is in flight, the device "shows" the new pm25.
    var changed = baseState
    changed.pm25 = 99
    await device.setState(changed)

    try? await Task.sleep(for: .milliseconds(40))
    // A poll during pending did not overwrite the state with a stale value.
    #expect(controller.state?.pm25 == 18)

    _ = await sendTask.value
    #expect(controller.state?.sound == true)
    #expect(controller.state?.pm25 == 99)
    controller.stop()
}

// MARK: - State streams

@MainActor
@Test func observationNotifiesOnChange() async {
    // The mechanism the CLI `watch` relies on: withObservationTracking must wake up.
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())
    let observed = Mutex(false)
    withObservationTracking {
        _ = controller.connection
        _ = controller.state
    } onChange: {
        observed.withLock { $0 = true }
    }
    controller.start()
    await waitUntil("observation fired") { observed.withLock { $0 } }
    controller.stop()
}

@MainActor
@Test func stateUpdatesDeliversToMultipleSubscribers() async {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())

    var first = controller.stateUpdates().makeAsyncIterator()
    var second = controller.stateUpdates().makeAsyncIterator()

    controller.start()
    let firstState = await first.next()
    let secondState = await second.next()
    #expect(firstState == baseState)
    #expect(secondState == baseState)
    controller.stop()
}

@MainActor
@Test func stopFinishesStreams() async {
    let device = FakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())

    var iterator = controller.stateUpdates().makeAsyncIterator()
    controller.stop()
    #expect(await iterator.next() == nil)
}

// MARK: - Overlapping commands

@MainActor
@Test(arguments: [false, true])
func olderReadBackCannotUndoNewerCommand(newerStillPending: Bool) async throws {
    let device = AutomationFakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())
    await controller.refreshNow()
    let oldGate = CommandTestGate()
    let newGate = CommandTestGate()
    defer { Task { await oldGate.release(); await newGate.release() } }
    await device.enqueueRead(gate: oldGate)
    let older = Task { try await controller.send(.power(false)) }
    await oldGate.waitUntilEntered()

    if newerStillPending { await device.enqueueRead(gate: newGate) }
    let newer = Task { try await controller.send(.power(true)) }
    if newerStillPending {
        await newGate.waitUntilEntered()
    } else {
        try await newer.value
    }
    await oldGate.release()
    await #expect(throws: DeviceError.superseded) { try await older.value }
    #expect(controller.state == baseState)
    #expect(controller.pending == (newerStillPending ? .power(true) : nil))
    await newGate.release()
    try await newer.value
    #expect(controller.state == baseState)
    #expect(controller.pending == nil)
}

@MainActor
@Test(arguments: [false, true])
func olderFailedConfirmationCannotPublishOrClearNewerPending(newerStillPending: Bool) async throws {
    let device = AutomationFakeDevice(state: baseState)
    await device.setAppliesCommands(false)
    let controller = PurifierController(
        device: device, policy: fastPolicy(confirmAttempts: 3, confirmInterval: .zero)
    )
    await controller.refreshNow()
    var staleRead = baseState
    staleRead.pm25 = 99
    await device.setState(staleRead)
    // All three reads mismatch power(false); hold the last reply after capturing it.
    let oldGate = CommandTestGate()
    let newGate = CommandTestGate()
    defer { Task { await oldGate.release(); await newGate.release() } }
    await device.enqueueRead()
    await device.enqueueRead()
    await device.enqueueRead(gate: oldGate)
    let older = Task { try await controller.send(.power(false)) }
    await oldGate.waitUntilEntered()

    await device.setAppliesCommands(true)
    if newerStillPending { await device.enqueueRead(gate: newGate) }
    let newer = Task { try await controller.send(.sound(true)) }
    if newerStillPending {
        await newGate.waitUntilEntered()
    } else {
        try await newer.value
    }
    let confirmedBeforeOldReply = controller.state
    await oldGate.release()
    await #expect(throws: DeviceError.superseded) { try await older.value }
    #expect(controller.state == confirmedBeforeOldReply)
    #expect(controller.pending == (newerStillPending ? .sound(true) : nil))
    await newGate.release()
    try await newer.value
    #expect(controller.state?.sound == true)
    #expect(controller.pending == nil)
}

@MainActor
@Test func supersededFailedReadDoesNotRetry() async throws {
    let device = AutomationFakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())
    let gate = CommandTestGate()
    defer { Task { await gate.release() } }
    await device.enqueueRead(gate: gate, error: .timeout)
    let older = Task { try await controller.send(.power(false)) }
    await gate.waitUntilEntered()
    try await controller.send(.power(true))
    let reads = await device.readCount
    await gate.release()
    await #expect(throws: DeviceError.superseded) { try await older.value }
    #expect(await device.readCount == reads)
    #expect(controller.state?.isOn == true)
}

@MainActor
@Test(arguments: [false, true])
func supersededApplyCannotClearPendingOrStartReadBack(applyFails: Bool) async throws {
    let device = AutomationFakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())
    let oldGate = CommandTestGate()
    let newGate = CommandTestGate()
    defer { Task { await oldGate.release(); await newGate.release() } }
    await device.gateNextApply(oldGate)
    let older = Task { try await controller.send(.power(false)) }
    await oldGate.waitUntilEntered()
    await device.enqueueRead(gate: newGate)
    let newer = Task { try await controller.send(.sound(true)) }
    await newGate.waitUntilEntered()
    if applyFails { await device.setApplyError(.timeout) }
    await oldGate.release()
    await #expect(throws: DeviceError.superseded) { try await older.value }
    #expect(controller.pending == .sound(true))
    #expect(await device.readCount == 1)
    #expect(controller.connection == .connecting)
    #expect(controller.state == nil)
    await newGate.release()
    try await newer.value
    #expect(controller.state?.sound == true)
}

@MainActor
@Test(arguments: [false, true])
func stopDuringReadBackStillThrowsCancellation(readFails: Bool) async {
    let device = AutomationFakeDevice(state: baseState)
    let controller = PurifierController(device: device, policy: fastPolicy())
    await controller.refreshNow()
    let gate = CommandTestGate()
    defer { Task { await gate.release() } }
    await device.enqueueRead(gate: gate, error: readFails ? .timeout : nil)
    let sending = Task { try await controller.send(.power(false)) }
    await gate.waitUntilEntered()
    controller.stop()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await sending.value }
    #expect(controller.state == baseState)
    #expect(controller.pending == nil)
    #expect(await device.readCount == 2)
}
