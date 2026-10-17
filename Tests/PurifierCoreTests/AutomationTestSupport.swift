// Shared test helpers for the automation tests: a fake device,
// a controlled clock and short policies. No waits of seconds.
import Foundation
import Synchronization
import Testing
@testable import PurifierCore

/// Fake device: applies commands (or not) and returns the given state.
actor AutomationFakeDevice: PurifierDevice {
    private var state: PurifierState
    private var appliesCommands = true
    private var applyError: MiIOError?
    private var readSteps: [(gate: CommandTestGate?, error: MiIOError?)] = []
    private var applyGate: CommandTestGate?
    private(set) var readCount = 0
    private(set) var applied: [PurifierCommand] = []

    init(state: PurifierState) {
        self.state = state
    }

    func readState() async throws -> PurifierState {
        readCount += 1
        let reply = state
        if !readSteps.isEmpty {
            let step = readSteps.removeFirst()
            if let gate = step.gate { await gate.wait() }
            if let error = step.error { throw error }
        }
        return reply
    }

    func apply(_ command: PurifierCommand) async throws {
        let gate = applyGate
        applyGate = nil
        if let gate { await gate.wait() }
        if let applyError { throw applyError }
        applied.append(command)
        if appliesCommands { state = state.applying(command) }
    }

    func setState(_ newState: PurifierState) { state = newState }
    func setAppliesCommands(_ flag: Bool) { appliesCommands = flag }
    func setApplyError(_ error: MiIOError?) { applyError = error }
    func enqueueRead(gate: CommandTestGate? = nil, error: MiIOError? = nil) {
        readSteps.append((gate, error))
    }
    func gateNextApply(_ gate: CommandTestGate) { applyGate = gate }
}

/// Captures a suspension point without wall-clock sleeps. Late replies ignore cancellation.
actor CommandTestGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let entries = entryWaiters
        entryWaiters.removeAll()
        for waiter in entries { waiter.resume() }
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Controlled clock for the engine: the time is set by the test.
final class AutomationClock: Sendable {
    private let storage: Mutex<Date>

    init(_ start: Date) {
        storage = Mutex(start)
    }

    var now: Date { storage.withLock { $0 } }
    func set(_ date: Date) { storage.withLock { $0 = date } }
}

func automationState(
    isOn: Bool = true,
    mode: PurifierMode = .auto,
    pm25: Int = 10,
    favoriteLevel: Int = 9
) -> PurifierState {
    PurifierState(
        isOn: isOn,
        fault: .none,
        mode: mode,
        pm25: pm25,
        filterPercent: 64,
        filterHoursUsed: 100,
        filterDaysLeft: 186,
        sound: false,
        childLock: false,
        screen: .bright,
        motorRPM: 416,
        favoriteLevel: favoriteLevel
    )
}

func automationPolicy(
    panelClosed: Duration = .milliseconds(5),
    confirmAttempts: Int = 5,
    confirmInterval: Duration = .milliseconds(2)
) -> PollingPolicy {
    PollingPolicy(
        panelOpen: .milliseconds(5),
        panelClosed: panelClosed,
        confirmAttempts: confirmAttempts,
        confirmInterval: confirmInterval,
        failuresBeforeUnreachable: 2
    )
}

/// Waits for a condition with a timeout, without long sleeps.
@MainActor
func waitFor(
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

/// Calendar with the Europe/Kyiv zone (to check the daylight saving time transition).
func kyivCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
    return calendar
}
