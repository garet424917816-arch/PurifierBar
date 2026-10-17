// Device controller: one background polling loop, confirmation of writes,
// availability tracking. For the panel (T3) and the automations (T4).
import Foundation
import Observation

/// Holds the typed state and executes commands. All state is on the main actor;
/// network I/O happens outside it (in `PurifierDevice`).
@MainActor
@Observable
public final class PurifierController {
    /// Only the value confirmed by the device.
    public private(set) var state: PurifierState?
    public private(set) var connection: Connection = .connecting
    /// A command waiting for confirmation.
    public private(set) var pending: PurifierCommand?

    /// Opening the panel (false -> true) wakes the loop: an immediate poll and the `panelOpen` interval.
    public var isPanelOpen: Bool {
        get { panelIsOpen }
        set {
            let wasOpen = panelIsOpen
            panelIsOpen = newValue
            if !wasOpen && newValue { wake() }
        }
    }

    @ObservationIgnored private var panelIsOpen = false
    @ObservationIgnored private let device: PurifierDevice
    @ObservationIgnored private let policy: PollingPolicy

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Start generation: grows at `stop()`. Reads and read-backs that started
    /// earlier see the generation changed and do not publish state or continue.
    @ObservationIgnored private var epoch = 0
    /// Newer means a later valid call to send, not the order of writes on the device.
    /// In-flight device writes continue, but only the latest call may publish its result.
    @ObservationIgnored private var commandGeneration = 0
    @ObservationIgnored private var consecutiveFailures = 0
    /// Counter of completed polls; for `refreshNow`.
    @ObservationIgnored private var pollCount = 0
    /// Grows after each confirmed write: a poll that started earlier
    /// must not overwrite a fresh confirmed state.
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var pollWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<PurifierState>.Continuation] = [:]

    public init(device: PurifierDevice, policy: PollingPolicy = .standard) {
        self.device = device
        self.policy = policy
    }

    /// Starts the polling loop. A repeated call - no effect.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops the loop and ends the state streams. No live tasks afterwards.
    public func stop() {
        // New generation: everything already started (reads, read-backs) becomes stale.
        epoch += 1
        loopTask?.cancel()
        loopTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        pending = nil
        let waiters = pollWaiters
        pollWaiters = []
        for waiter in waiters { waiter.continuation.resume() }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    /// Out-of-turn poll: wakes the loop and waits for a fresh read.
    public func refreshNow() async {
        guard loopTask != nil else {
            await performPoll()
            return
        }
        let generation = pollCount
        wake()
        await waitForPoll(after: generation)
    }

    /// Writes the command and waits for the read-back confirmation.
    public func send(_ command: PurifierCommand) async throws {
        try command.validated()
        let epoch = self.epoch
        commandGeneration += 1
        let generation = commandGeneration
        pending = command
        do {
            try await device.apply(command)
        } catch {
            try checkCommand(epoch: epoch, generation: generation)
            pending = nil
            throw error
        }
        try checkCommand(epoch: epoch, generation: generation)
        var lastRead: PurifierState?
        for attempt in 0..<max(1, policy.confirmAttempts) {
            if attempt > 0 { await pause(policy.confirmInterval) }
            try checkCommand(epoch: epoch, generation: generation)
            let reply = try? await device.readState()
            // Check failures too: a stale command must not retry or clear a newer pending write.
            try checkCommand(epoch: epoch, generation: generation)
            guard let read = reply else { continue }
            lastRead = read
            if read.matches(command) {
                writeGeneration += 1
                pending = nil
                consecutiveFailures = 0
                if connection != .online { connection = .online }
                publish(read)
                return
            }
        }
        pending = nil
        if let lastRead { publish(lastRead) }
        throw DeviceError.notConfirmed
    }

    private func checkCommand(epoch: Int, generation: Int) throws {
        guard epoch == self.epoch else { throw CancellationError() }
        guard generation == commandGeneration else { throw DeviceError.superseded }
    }

    /// Each new confirmed state, for several subscribers. Ends at `stop()`.
    public func stateUpdates() -> AsyncStream<PurifierState> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    // MARK: - Polling loop

    private func run() async {
        while !Task.isCancelled {
            await performPoll()
            if Task.isCancelled { break }
            let interval = isPanelOpen ? policy.panelOpen : policy.panelClosed
            await sleepInterruptibly(interval)
        }
    }

    private func performPoll() async {
        let generation = writeGeneration
        let epoch = self.epoch
        let wasPending = pending != nil
        do {
            let newState = try await device.readState()
            // stop() during a read: the reply is stale, we change nothing.
            guard epoch == self.epoch else { return }
            consecutiveFailures = 0
            if connection != .online { connection = .online }
            // During a write the poll does not publish state: it may be stale.
            if !wasPending && pending == nil && writeGeneration == generation {
                publish(newState)
            }
        } catch {
            guard epoch == self.epoch else { return }
            consecutiveFailures += 1
            if consecutiveFailures >= policy.failuresBeforeUnreachable {
                connection = .unreachable
            }
        }
        pollCount += 1
        resumePollWaiters()
    }

    private func publish(_ newState: PurifierState) {
        guard newState != state else { return }
        state = newState
        for continuation in subscribers.values { continuation.yield(newState) }
    }

    // MARK: - Waiting

    /// A sleep that `wake()` interrupts (panel change, refreshNow, stop).
    private func sleepInterruptibly(_ duration: Duration) async {
        let task = Task<Void, Never> {
            _ = try? await Task.sleep(for: duration, tolerance: duration / 10)
        }
        sleepTask = task
        await task.value
        if sleepTask == task { sleepTask = nil }
    }

    private func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration, tolerance: duration / 10)
    }

    private func wake() {
        sleepTask?.cancel()
        sleepTask = nil
    }

    private func resumePollWaiters() {
        guard !pollWaiters.isEmpty else { return }
        let ready = pollWaiters.filter { $0.target <= pollCount }
        guard !ready.isEmpty else { return }
        pollWaiters.removeAll { $0.target <= pollCount }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func waitForPoll(after generation: Int) async {
        if pollCount > generation { return }
        let target = generation + 1
        await withCheckedContinuation { continuation in
            pollWaiters.append((target, continuation))
        }
    }
}
