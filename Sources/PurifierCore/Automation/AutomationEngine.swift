// Automation engine: subscription to the controller states, threshold machine and schedule.
// Between events it sleeps in one task until the nearest deadline - no periodic timers.
import Foundation

/// Holds the threshold machine and the schedule. All work is on the main actor,
/// network I/O stays with the controller.
@MainActor
public final class AutomationEngine {
    public init(
        controller: PurifierController,
        settings: AutomationSettings,
        favoriteLevelRange: ClosedRange<Int> = ThresholdSettings.boostLevelRange,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.controller = controller
        self.favoriteLevelRange = favoriteLevelRange
        self.calendar = calendar
        self.now = now
        self.currentSettings = settings
    }

    /// Settings change -> full rescheduling.
    public var settings: AutomationSettings {
        get { currentSettings }
        set {
            currentSettings = newValue
            scheduledFire = nil
            thresholdRecheckAt = nil
            commandBackoffUntil = nil
            poke()
        }
    }

    public private(set) var isBoosting = false

    /// Manual command from the panel. Only fan control (power, mode, levels) cancels the boost;
    /// sound, child lock and screen pass straight to the controller.
    public func userSend(_ command: PurifierCommand) async throws {
        if Self.controlsFan(command) {
            machine.cancelBoost(state: controller.state, settings: currentSettings.threshold)
            updateIsBoosting()
            thresholdRecheckAt = nil
            commandBackoffUntil = nil
            poke()
        }
        try await controller.send(command)
    }

    nonisolated static func controlsFan(_ command: PurifierCommand) -> Bool {
        switch command {
        case .power, .mode, .favoriteLevel, .manualLevel: return true
        case .sound, .childLock, .screen: return false
        }
    }

    public func start() {
        guard loopTask == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        pokes = stream
        pokeContinuation = continuation

        // Controller states only wake the loop - the freshest confirmed `controller.state` is
        // always evaluated, so stale states from the buffer do no harm.
        let source = controller
        stateTask = Task {
            for await _ in source.stateUpdates() {
                continuation.yield()
            }
        }

        loopTask = Task { [weak self] in
            await self?.run(stream)
        }
    }

    /// Stops the engine: no live tasks afterwards.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        stateTask?.cancel()
        stateTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        pokeContinuation?.finish()
        pokeContinuation = nil
        pokes = nil
    }

    /// Mac wake-up, time or zone change: the schedule is recalculated from `now`,
    /// so rules missed during sleep are not caught up.
    public func reschedule() {
        scheduledFire = Schedule.nextFire(after: now(), rules: currentSettings.schedule, calendar: calendar)
        poke()
    }

    // MARK: - State

    private let favoriteLevelRange: ClosedRange<Int>
    private let controller: PurifierController
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var currentSettings: AutomationSettings
    private(set) var machine = ThresholdMachine()

    private var loopTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var pokes: AsyncStream<Void>?
    private var pokeContinuation: AsyncStream<Void>.Continuation?

    /// The nearest schedule trigger since the last recalculation.
    private var scheduledFire: (date: Date, rules: [ScheduleRule])?
    /// Deadline of the next threshold check without new data.
    private var thresholdRecheckAt: Date?
    /// After a failed command the threshold does not retry more often than once per 30 s.
    private(set) var commandBackoffUntil: Date?
    private static let commandRetryDelay: TimeInterval = 30

    // MARK: - Loop

    private func run(_ stream: AsyncStream<Void>) async {
        var iterator = stream.makeAsyncIterator()
        await reconcile()
        while !Task.isCancelled {
            guard await iterator.next() != nil else { break }
            if Task.isCancelled { break }
            await reconcile()
        }
    }

    // One event pass, also usable by tests with a controlled clock and no live loop.
    func reconcile() async {
        await fireDueSchedule()
        // stop() during a command: nothing is planned and nothing further is sent.
        guard !Task.isCancelled else { return }
        await applyThreshold()
        guard !Task.isCancelled else { return }
        scheduleDeadline(now: now())
    }

    private func fireDueSchedule() async {
        let current = now()
        if scheduledFire == nil {
            scheduledFire = Schedule.nextFire(after: current, rules: currentSettings.schedule, calendar: calendar)
        }
        guard let fire = scheduledFire, current >= fire.date else { return }
        scheduledFire = nil
        // Treat the schedule as a manual action: cancel without restore and wait for clean air.
        machine.cancelBoost(state: controller.state, settings: currentSettings.threshold)
        updateIsBoosting()
        thresholdRecheckAt = nil
        commandBackoffUntil = nil
        scheduledCommands: for rule in fire.rules {
            for command in rule.action.commands {
                guard !Task.isCancelled else { return }
                do {
                    try await controller.send(command)
                } catch DeviceError.superseded {
                    // A newer action takes precedence over the rest of this schedule batch.
                    break scheduledCommands
                } catch {
                    // An error of one command does not stop the engine.
                }
            }
        }
        scheduledFire = Schedule.nextFire(after: now(), rules: currentSettings.schedule, calendar: calendar)
    }

    private func applyThreshold() async {
        let current = now()
        guard let state = controller.state else { return }
        let backoffActive = commandBackoffUntil.map { current < $0 } ?? false

        let snapshot = machine
        let result = machine.evaluate(
            state: state, settings: currentSettings.threshold, now: current,
            favoriteLevelRange: favoriteLevelRange
        )

        guard !result.commands.isEmpty else {
            thresholdRecheckAt = result.recheckAt
            updateIsBoosting()
            // Evaluation continues always; we limit only the retry of the command.
            if !backoffActive { commandBackoffUntil = nil }
            return
        }

        // In the rollback window we do not send the command and do not change the phase.
        guard !backoffActive else {
            machine = snapshot
            thresholdRecheckAt = nil
            updateIsBoosting()
            return
        }

        thresholdRecheckAt = result.recheckAt
        updateIsBoosting()
        do {
            for command in result.commands {
                guard !Task.isCancelled else { return }
                try await controller.send(command)
            }
            commandBackoffUntil = nil
        } catch DeviceError.superseded {
            // The newer manual or scheduled action owns the phase and its deadlines.
            // Preserve its cancellation instead of restoring the old threshold snapshot.
            return
        } catch {
            // Failure: the phase does not change, the retry will be made not earlier than in 30 s.
            machine = snapshot
            thresholdRecheckAt = nil
            updateIsBoosting()
            commandBackoffUntil = current.addingTimeInterval(Self.commandRetryDelay)
        }
    }

    private func scheduleDeadline(now current: Date) {
        deadlineTask?.cancel()
        deadlineTask = nil

        var earliest: Date?
        var tolerance: TimeInterval = 1
        func consider(_ candidate: Date, _ candidateTolerance: TimeInterval) {
            if earliest == nil || candidate < earliest! {
                earliest = candidate
                tolerance = candidateTolerance
            }
        }
        if let thresholdRecheckAt { consider(thresholdRecheckAt, 1) }
        if let commandBackoffUntil { consider(commandBackoffUntil, 1) }
        if let scheduledFire { consider(scheduledFire.date, 5) }
        guard let target = earliest else { return }

        let interval = max(0, target.timeIntervalSince(current))
        let effectiveTolerance = min(tolerance, interval)
        let continuation = pokeContinuation
        deadlineTask = Task {
            try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(effectiveTolerance))
            guard !Task.isCancelled else { return }
            continuation?.yield()
        }
    }

    private func updateIsBoosting() {
        if case .boosting = machine.phase {
            isBoosting = true
        } else {
            isBoosting = false
        }
    }

    private func poke() {
        pokeContinuation?.yield()
    }
}
