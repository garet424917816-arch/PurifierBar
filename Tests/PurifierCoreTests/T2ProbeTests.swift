import CoreFoundation
import Foundation
import PurifierCore
import Testing

// Independent reference from the contract: the exact allowed set, no dependency on the T2 code.
private enum T2Fixture {
    static let ids = [
        PropertyID(siid: 2, piid: 1), PropertyID(siid: 2, piid: 2),
        PropertyID(siid: 2, piid: 4), PropertyID(siid: 3, piid: 4),
        PropertyID(siid: 4, piid: 1), PropertyID(siid: 4, piid: 3),
        PropertyID(siid: 4, piid: 4), PropertyID(siid: 6, piid: 1),
        PropertyID(siid: 8, piid: 1), PropertyID(siid: 13, piid: 2),
        PropertyID(siid: 9, piid: 1), PropertyID(siid: 9, piid: 11),
    ]

    static func state(isOn: Bool = false, pm25: Int = 37) -> PurifierState {
        PurifierState(
            isOn: isOn, fault: .sensorLost, mode: .sleep, pm25: pm25,
            filterPercent: 73, filterHoursUsed: 126, filterDaysLeft: 245,
            sound: false, childLock: true, screen: .dim, motorRPM: 1357, favoriteLevel: 4
        )
    }

    static func reply(
        fault: Int = 3, mode: Int = 1, screen: Int = 1, omitting: PropertyID? = nil
    ) throws -> Data {
        let values: [(PropertyID, MIoTValue)] = [
            (ids[0], .bool(false)), (ids[1], .int(fault)), (ids[2], .int(mode)),
            (ids[3], .int(37)), (ids[4], .int(73)), (ids[5], .int(126)),
            (ids[6], .int(245)), (ids[7], .bool(false)), (ids[8], .bool(true)),
            (ids[9], .int(screen)), (ids[10], .int(1357)), (ids[11], .int(4)),
        ]
        // A different reply order catches matching by position instead of siid/piid.
        let rows: [[String: Any]] = values.reversed().compactMap { id, value in
            guard id != omitting else { return nil }
            let jsonValue: Any
            switch value {
            case .bool(let flag): jsonValue = flag
            case .int(let number): jsonValue = number
            }
            return ["siid": id.siid, "piid": id.piid, "code": 0, "value": jsonValue]
        }
        return try JSONSerialization.data(withJSONObject: ["result": rows])
    }

    static func policy(
        open: Duration = .milliseconds(40), closed: Duration = .milliseconds(120),
        attempts: Int = 4, confirm: Duration = .milliseconds(40), failures: Int = 2
    ) -> PollingPolicy {
        PollingPolicy(
            panelOpen: open, panelClosed: closed, confirmAttempts: attempts,
            confirmInterval: confirm, failuresBeforeUnreachable: failures
        )
    }
}

private actor T2Transport: MiIOTransport {
    struct Call: Sendable {
        let method: String
        let params: Data
    }

    private let reply: Data
    private let error: MiIOError?
    private var calls: [Call] = []

    init(reply: Data = Data(#"{"result":[]}"#.utf8), error: MiIOError? = nil) {
        self.reply = reply
        self.error = error
    }

    func call(method: String, params: Data) async throws -> Data {
        calls.append(Call(method: method, params: params))
        if let error { throw error }
        return reply
    }

    func recordedCalls() -> [Call] { calls }
}

// The gate deliberately does not react to cancellation: a UDP reply may also arrive late.
// Each test opens them in defer, so a failed check does not leave a hung task.
private actor T2Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor T2Device: PurifierDevice {
    enum Read: Sendable {
        case state(PurifierState)
        case failure(MiIOError)
        case gated(PurifierState, T2Gate)
        case delayed(PurifierState, Duration)
    }

    struct Snapshot: Sendable {
        let reads: Int
        let completedReads: Int
        let activeReads: Int
        let commands: [PurifierCommand]
        var calls: Int { reads + commands.count }
    }

    private var fallback: PurifierState
    private var script: [Read] = []
    private var reads = 0
    private var completedReads = 0
    private var activeReads = 0
    private var commands: [PurifierCommand] = []
    private var applyError: MiIOError?
    private var applyGate: T2Gate?

    init(state: PurifierState = T2Fixture.state()) { fallback = state }

    func configure(
        reads: [Read] = [], fallback: PurifierState? = nil,
        applyError: MiIOError? = nil, applyGate: T2Gate? = nil
    ) {
        script = reads
        if let fallback { self.fallback = fallback }
        self.applyError = applyError
        self.applyGate = applyGate
    }

    func readState() async throws -> PurifierState {
        reads += 1
        activeReads += 1
        let next = script.isEmpty ? Read.state(fallback) : script.removeFirst()
        defer {
            completedReads += 1
            activeReads -= 1
        }
        switch next {
        case .state(let state): return state
        case .failure(let error): throw error
        case .gated(let state, let gate):
            await gate.wait()
            return state
        case .delayed(let state, let duration):
            try await Task.sleep(for: duration)
            return state
        }
    }

    func apply(_ command: PurifierCommand) async throws {
        commands.append(command)
        if let applyGate { await applyGate.wait() }
        if let applyError { throw applyError }
        // Only the read scenario changes the state: apply itself confirms nothing.
    }

    func snapshot() -> Snapshot {
        Snapshot(
            reads: reads, completedReads: completedReads,
            activeReads: activeReads, commands: commands
        )
    }
}

private actor T2Updates {
    private var states: [PurifierState] = []
    private var finished = false

    func append(_ state: PurifierState) { states.append(state) }
    func finish() { finished = true }
    func snapshot() -> (states: [PurifierState], finished: Bool) { (states, finished) }
}

private struct T2WriteCase: Sendable {
    let command: PurifierCommand
    let values: [(PropertyID, MIoTValue)]

    static let all: [Self] = [
        Self(command: .power(false), values: [(PropertyID(siid: 2, piid: 1), .bool(false))]),
        Self(command: .power(true), values: [(PropertyID(siid: 2, piid: 1), .bool(true))]),
        Self(command: .mode(.auto), values: [(PropertyID(siid: 2, piid: 4), .int(0))]),
        Self(command: .mode(.sleep), values: [(PropertyID(siid: 2, piid: 4), .int(1))]),
        Self(command: .mode(.manual), values: [(PropertyID(siid: 2, piid: 4), .int(2))]),
        Self(command: .favoriteLevel(0), values: [(PropertyID(siid: 9, piid: 11), .int(0))]),
        Self(command: .favoriteLevel(14), values: [(PropertyID(siid: 9, piid: 11), .int(14))]),
        Self(command: .sound(false), values: [(PropertyID(siid: 6, piid: 1), .bool(false))]),
        Self(command: .sound(true), values: [(PropertyID(siid: 6, piid: 1), .bool(true))]),
        Self(command: .childLock(false), values: [(PropertyID(siid: 8, piid: 1), .bool(false))]),
        Self(command: .childLock(true), values: [(PropertyID(siid: 8, piid: 1), .bool(true))]),
        Self(command: .screen(.off), values: [(PropertyID(siid: 13, piid: 2), .int(0))]),
        Self(command: .screen(.bright), values: [(PropertyID(siid: 13, piid: 2), .int(2))]),
        Self(command: .screen(.dim), values: [(PropertyID(siid: 13, piid: 2), .int(1))]),
        Self(command: .manualLevel(0), values: [
            (PropertyID(siid: 2, piid: 4), .int(2)), (PropertyID(siid: 9, piid: 11), .int(0)),
        ]),
        Self(command: .manualLevel(14), values: [
            (PropertyID(siid: 2, piid: 4), .int(2)), (PropertyID(siid: 9, piid: 11), .int(14)),
        ]),
    ]
}

@Suite("Independent contract probes T2", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct T2ProbeTests {
    // This wait is only in tests, with a bounded time and a sleep instead of a busy-wait.
    private func eventually(
        within timeout: Duration = .seconds(2),
        _ predicate: @MainActor () async -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        return await predicate()
    }

    private func purifier(_ transport: T2Transport) -> MIoTPurifier {
        MIoTPurifier(client: MIoTClient(transport: transport, deviceID: "123456789"))
    }

    private func rows(_ data: Data) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func propertyID(_ row: [String: Any]) throws -> PropertyID {
        PropertyID(siid: try #require(row["siid"] as? Int), piid: try #require(row["piid"] as? Int))
    }

    private func collect(_ stream: AsyncStream<PurifierState>, into recorder: T2Updates) -> Task<Void, Never> {
        Task {
            for await state in stream { await recorder.append(state) }
            await recorder.finish()
        }
    }

    @Test("readState requests exactly 12 allowed properties and maps all fields")
    func readRequestsExactlyContractProperties() async throws {
        let transport = T2Transport(reply: try T2Fixture.reply())
        #expect(try await purifier(transport).readState() == T2Fixture.state())
        let calls = await transport.recordedCalls()
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.method == "get_properties")
        let parameters = try rows(call.params)
        #expect(parameters.count == 12)
        #expect(try Set(parameters.map(propertyID)) == Set(T2Fixture.ids))
        for row in parameters {
            #expect(row["did"] as? String == "123456789")
            #expect(row["value"] == nil)
        }
    }

    @Test("each missing property gives incompleteState", arguments: T2Fixture.ids)
    func missingPropertyIsIncomplete(id: PropertyID) async throws {
        let transport = T2Transport(reply: try T2Fixture.reply(omitting: id))
        await #expect(throws: DeviceError.incompleteState) {
            _ = try await purifier(transport).readState()
        }
    }

    @Test("mapping of fault codes", arguments: [0, 2, 3, 71, -4])
    func faultMapping(code: Int) async throws {
        let transport = T2Transport(reply: try T2Fixture.reply(fault: code))
        let state = try await purifier(transport).readState()
        let expected: PurifierFault
        switch code {
        case 0: expected = .none
        case 2: expected = .motorStuck
        case 3: expected = .sensorLost
        default: expected = .other(code)
        }
        #expect(state.fault == expected)
    }

    @Test("mapping of all modes and brightness levels", arguments: PurifierMode.allCases, ScreenBrightness.allCases)
    func modeAndScreenMapping(mode: PurifierMode, screen: ScreenBrightness) async throws {
        let transport = T2Transport(reply: try T2Fixture.reply(mode: mode.rawValue, screen: screen.rawValue))
        let state = try await purifier(transport).readState()
        #expect(state.mode == mode)
        #expect(state.screen == screen)
    }

    @Test("apply maps each command to one set_properties without read-back", arguments: T2WriteCase.all)
    private func commandMapping(example: T2WriteCase) async throws {
        let transport = T2Transport()
        try await purifier(transport).apply(example.command)
        let calls = await transport.recordedCalls()
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.method == "set_properties")
        let parameters = try rows(call.params)
        #expect(parameters.count == example.values.count)
        let expected = Dictionary(uniqueKeysWithValues: example.values)
        #expect(try Set(parameters.map(propertyID)) == Set(expected.keys))
        for row in parameters {
            #expect(row["did"] as? String == "123456789")
            let value = try #require(row["value"] as? NSNumber)
            let id = try propertyID(row)
            switch try #require(expected[id]) {
            case .bool(let flag):
                #expect(CFGetTypeID(value) == CFBooleanGetTypeID())
                #expect(value.boolValue == flag)
            case .int(let number):
                #expect(CFGetTypeID(value) != CFBooleanGetTypeID())
                #expect(value.doubleValue == Double(number))
            }
        }
    }

    @Test("levels outside the range are rejected before the transport", arguments: [-1, 15], [false, true])
    func invalidLevelsNeverReachTransport(level: Int, manual: Bool) async {
        let transport = T2Transport()
        let command: PurifierCommand = manual ? .manualLevel(level) : .favoriteLevel(level)
        await #expect(throws: DeviceError.invalidValue) { try await purifier(transport).apply(command) }
        #expect(await transport.recordedCalls().isEmpty)
    }

    @Test("MIoTPurifier preserves transport errors", arguments: [false, true])
    func transportErrorsPropagate(isWrite: Bool) async {
        let transport = T2Transport(error: .timeout)
        await #expect(throws: MiIOError.timeout) {
            if isWrite { try await purifier(transport).apply(.power(true)) }
            else { _ = try await purifier(transport).readState() }
        }
    }

    @Test("standard policy has the contract values")
    func standardPolicy() {
        let policy = PollingPolicy.standard
        #expect(policy.panelOpen == .seconds(5))
        #expect(policy.panelClosed == .seconds(30))
        #expect(policy.confirmAttempts == 8)
        #expect(policy.confirmInterval == .milliseconds(250))
        #expect(policy.failuresBeforeUnreachable == 2)
    }

    @Test("initial controller state and refreshNow")
    func initialStateAndRefresh() async {
        let device = T2Device()
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer { controller.stop() }
        #expect(controller.state == nil)
        #expect(controller.connection == .connecting)
        #expect(controller.pending == nil)
        #expect(!controller.isPanelOpen)
        await controller.refreshNow()
        #expect(controller.state == T2Fixture.state())
        #expect(controller.connection == .online)
        #expect(await device.snapshot().reads == 1)
    }

    @Test("start polls, a repeated start does not multiply cycles or wake-ups")
    func pollingAndIdempotentStart() async throws {
        let device = T2Device()
        let controller = PurifierController(device: device, policy: T2Fixture.policy(closed: .milliseconds(100)))
        defer { controller.stop() }
        controller.start()
        controller.start()
        try #require(await eventually { controller.state != nil })
        let before = await device.snapshot().reads
        try await Task.sleep(for: .milliseconds(650))
        let count = await device.snapshot().reads - before
        #expect((3...9).contains(count))
        #expect(controller.connection == .online)
    }

    @Test("opening the panel reads immediately and speeds up the cycle, closing slows it down")
    func panelChangesPollingImmediately() async throws {
        let device = T2Device()
        let controller = PurifierController(
            device: device, policy: T2Fixture.policy(open: .milliseconds(60), closed: .milliseconds(1200))
        )
        defer { controller.stop() }
        controller.start()
        try #require(await eventually { controller.state != nil })
        let closedBefore = await device.snapshot().reads
        try await Task.sleep(for: .milliseconds(250))
        #expect((0...1).contains(await device.snapshot().reads - closedBefore))
        let changed = T2Fixture.state(pm25: 91)
        await device.configure(fallback: changed)
        controller.isPanelOpen = true
        // 350 ms with a margin, but well less than the rest of the closed interval.
        try #require(await eventually(within: .milliseconds(350)) { controller.state == changed })
        let openBefore = await device.snapshot().reads
        try await Task.sleep(for: .milliseconds(650))
        let openCount = await device.snapshot().reads - openBefore
        #expect((5...16).contains(openCount))
        controller.isPanelOpen = false
        let closeBefore = await device.snapshot().reads
        try await Task.sleep(for: .milliseconds(300))
        #expect(await device.snapshot().reads - closeBefore <= 1)
    }

    @Test("failure threshold keeps the last state, success restores online", arguments: [2, 3])
    func unreachableAndRecovery(threshold: Int) async {
        let device = T2Device()
        let controller = PurifierController(device: device, policy: T2Fixture.policy(failures: threshold))
        defer { controller.stop() }
        await controller.refreshNow()
        let known = controller.state
        await device.configure(reads: Array(repeating: .failure(.timeout), count: threshold))
        for index in 1...threshold {
            await controller.refreshNow()
            #expect(controller.connection == (index == threshold ? .unreachable : .online))
            #expect(controller.state == known)
        }
        let recovered = T2Fixture.state(pm25: 8)
        await device.configure(fallback: recovered)
        await controller.refreshNow()
        #expect(controller.connection == .online)
        #expect(controller.state == recovered)
    }

    @Test("a successful read resets the consecutive failure counter")
    func successResetsFailureCount() async {
        let device = T2Device()
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer { controller.stop() }
        await controller.refreshNow()
        await device.configure(reads: [.failure(.timeout), .state(T2Fixture.state()), .failure(.timeout)])
        for _ in 0..<3 {
            await controller.refreshNow()
            #expect(controller.connection == .online)
        }
    }

    @Test("polling loop survives transport errors and restores availability")
    func pollingRecoversFromTransportFailures() async throws {
        let known = T2Fixture.state()
        let recovered = T2Fixture.state(pm25: 7)
        let gate = T2Gate()
        let device = T2Device(state: recovered)
        await device.configure(reads: [
            .state(known), .failure(.timeout), .failure(.timeout), .gated(recovered, gate),
        ])
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer {
            controller.stop()
            Task { await gate.open() }
        }
        controller.start()
        try #require(await eventually { controller.connection == .unreachable })
        #expect(controller.state == known)
        await gate.open()
        try #require(await eventually { controller.connection == .online && controller.state == recovered })
    }

    @Test("send is confirmed on the third attempt and keeps the full read-back state")
    func confirmsOnThirdRead() async throws {
        let old = T2Fixture.state()
        let confirmed = T2Fixture.state(isOn: true, pm25: 9)
        let device = T2Device(state: old)
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer { controller.stop() }
        await controller.refreshNow()
        let before = await device.snapshot().reads
        await device.configure(reads: [.state(old), .state(old), .state(confirmed)], fallback: confirmed)
        let clock = ContinuousClock()
        let started = clock.now
        try await controller.send(.power(true))
        #expect(await device.snapshot().reads - before == 3)
        #expect(await device.snapshot().commands == [.power(true)])
        // Two pauses of 40 ms; the lower bound catches a loop without sleep.
        #expect(started.duration(to: clock.now) >= .milliseconds(60))
        #expect(controller.state == confirmed)
        #expect(controller.pending == nil)
    }

    @Test("each command is confirmed by its corresponding field", arguments: [
        PurifierCommand.power(true), .mode(.auto), .mode(.manual), .favoriteLevel(14),
        .sound(true), .childLock(false), .screen(.off), .screen(.bright), .manualLevel(14),
    ])
    func commandConfirmationUsesCorrectField(command: PurifierCommand) async throws {
        let old = T2Fixture.state()
        var confirmed = old
        confirmed.pm25 = 11
        switch command {
        case .power(let value): confirmed.isOn = value
        case .mode(let value): confirmed.mode = value
        case .favoriteLevel(let value): confirmed.favoriteLevel = value
        case .sound(let value): confirmed.sound = value
        case .childLock(let value): confirmed.childLock = value
        case .screen(let value): confirmed.screen = value
        case .manualLevel(let value):
            confirmed.mode = .manual
            confirmed.favoriteLevel = value
        }
        let device = T2Device(state: old)
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer { controller.stop() }
        await controller.refreshNow()
        let before = await device.snapshot().reads
        await device.configure(reads: [.state(old), .state(confirmed)], fallback: confirmed)
        try await controller.send(command)
        #expect(await device.snapshot().reads - before == 2)
        #expect(await device.snapshot().commands == [command])
        #expect(controller.state == confirmed)
        #expect(controller.pending == nil)
    }

    @Test("manualLevel requires confirmation of both mode and level")
    func manualConfirmationRequiresBothProperties() async throws {
        let old = T2Fixture.state()
        var modeOnly = old
        modeOnly.mode = .manual
        var levelOnly = old
        levelOnly.favoriteLevel = 14
        var both = modeOnly
        both.favoriteLevel = 14
        let device = T2Device(state: old)
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer { controller.stop() }
        await controller.refreshNow()
        let before = await device.snapshot().reads
        await device.configure(reads: [.state(modeOnly), .state(levelOnly), .state(both)], fallback: both)
        try await controller.send(.manualLevel(14))
        #expect(await device.snapshot().reads - before == 3)
        #expect(controller.state == both)
        #expect(controller.pending == nil)
    }

    @Test("unconfirmed send gives notConfirmed, clears pending, keeps the last reading")
    func unconfirmedSendKeepsLastRead() async throws {
        let old = T2Fixture.state()
        let last = T2Fixture.state(pm25: 94)
        let device = T2Device(state: old)
        let controller = PurifierController(device: device, policy: T2Fixture.policy(attempts: 3))
        defer { controller.stop() }
        await controller.refreshNow()
        let before = await device.snapshot().reads
        await device.configure(reads: [.state(old), .state(old), .state(last)], fallback: last)
        await #expect(throws: DeviceError.notConfirmed) { try await controller.send(.power(true)) }
        #expect(await device.snapshot().reads - before == 3)
        #expect(controller.pending == nil)
        #expect(controller.state == last)
        let calls = await device.snapshot().calls
        try await Task.sleep(for: .milliseconds(200))
        #expect(await device.snapshot().calls == calls)
    }

    @Test("apply error propagates without read-back and clears pending")
    func applyFailureClearsPending() async throws {
        let device = T2Device()
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer { controller.stop() }
        await controller.refreshNow()
        await device.configure(applyError: .deviceError(code: -7))
        let before = await device.snapshot().reads
        await #expect(throws: MiIOError.deviceError(code: -7)) { try await controller.send(.power(true)) }
        #expect(controller.pending == nil)
        #expect(controller.state == T2Fixture.state())
        #expect(await device.snapshot().reads == before)
        #expect(await device.snapshot().commands == [.power(true)])
    }

    @Test("pending is visible during apply, state and streams are not optimistic")
    func pendingDoesNotPublishOptimisticState() async throws {
        let old = T2Fixture.state()
        let confirmed = T2Fixture.state(isOn: true, pm25: 12)
        let gate = T2Gate()
        let device = T2Device(state: old)
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        let recorder = T2Updates()
        let consumer = collect(controller.stateUpdates(), into: recorder)
        await controller.refreshNow()
        await device.configure(reads: [.state(confirmed)], fallback: confirmed, applyGate: gate)
        let sending = Task { try await controller.send(.power(true)) }
        defer {
            controller.stop()
            sending.cancel()
            consumer.cancel()
            Task { await gate.open() }
        }
        try #require(await eventually { await device.snapshot().commands.count == 1 })
        #expect(controller.pending == .power(true))
        #expect(controller.state == old)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await recorder.snapshot().states.allSatisfy { $0 == old })
        await gate.open()
        try await sending.value
        try #require(await eventually { await recorder.snapshot().states.contains(confirmed) })
        #expect(controller.state == confirmed)
        #expect(controller.pending == nil)
    }

    @Test("a late poll does not overwrite a confirmed send")
    func stalePollingCannotOverwriteConfirmation() async throws {
        let old = T2Fixture.state()
        let confirmed = T2Fixture.state(isOn: true, pm25: 6)
        let gate = T2Gate()
        let device = T2Device(state: old)
        let controller = PurifierController(device: device, policy: T2Fixture.policy(closed: .milliseconds(1200)))
        let recorder = T2Updates()
        let consumer = collect(controller.stateUpdates(), into: recorder)
        await controller.refreshNow()
        await device.configure(reads: [.gated(old, gate)], fallback: confirmed)
        controller.start()
        defer {
            controller.stop()
            consumer.cancel()
            Task { await gate.open() }
        }
        try #require(await eventually { await device.snapshot().activeReads == 1 })
        let sending = Task { try await controller.send(.power(true)) }
        defer { sending.cancel() }
        try #require(await eventually { await device.snapshot().commands.count == 1 || controller.pending != nil })
        // Both strategies allowed: serializing I/O or discarding the stale reply.
        // If send reads in parallel, the old poll would return after the confirmation.
        _ = try await eventually(within: .milliseconds(250)) { controller.pending == nil && controller.state == confirmed }
        await gate.open()
        try await sending.value
        try #require(await eventually { await device.snapshot().activeReads == 0 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.state == confirmed)
        #expect(controller.pending == nil)
        let states = await recorder.snapshot().states
        let confirmedIndex = try #require(states.firstIndex(of: confirmed))
        #expect(states.suffix(from: confirmedIndex).allSatisfy { $0 == confirmed })
    }

    @Test("stop halts polling in both modes", arguments: [false, true])
    func stopPreventsFurtherCalls(panelOpen: Bool) async throws {
        let device = T2Device()
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer { controller.stop() }
        controller.isPanelOpen = panelOpen
        controller.start()
        try #require(await eventually { await device.snapshot().reads >= 2 })
        controller.stop()
        controller.stop()
        let calls = await device.snapshot().calls
        try await Task.sleep(for: .milliseconds(600))
        #expect(await device.snapshot().calls == calls)
    }

    @Test("stop cancels the current read, which supports cancellation")
    func stopCancelsInFlightRead() async throws {
        let device = T2Device()
        await device.configure(reads: [.delayed(T2Fixture.state(), .seconds(5))])
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        defer { controller.stop() }
        controller.start()
        try #require(await eventually { await device.snapshot().activeReads == 1 })
        controller.stop()
        try #require(await eventually(within: .milliseconds(350)) { await device.snapshot().activeReads == 0 })
        let calls = await device.snapshot().calls
        try await Task.sleep(for: .milliseconds(400))
        #expect(await device.snapshot().calls == calls)
        #expect(controller.state == nil)
    }

    @Test("a reply after stop does not publish state and does not restart the cycle")
    func lateReadAfterStopIsIgnored() async throws {
        let gate = T2Gate()
        let device = T2Device()
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        await controller.refreshNow()
        let known = controller.state
        await device.configure(reads: [.gated(T2Fixture.state(pm25: 99), gate)])
        controller.start()
        defer {
            controller.stop()
            Task { await gate.open() }
        }
        try #require(await eventually { await device.snapshot().activeReads == 1 })
        controller.stop()
        let calls = await device.snapshot().calls
        await gate.open()
        try #require(await eventually { await device.snapshot().activeReads == 0 })
        try await Task.sleep(for: .milliseconds(450))
        #expect(await device.snapshot().calls == calls)
        #expect(controller.state == known)
    }

    @Test("stop ends the read-back of an active send and clears the live task")
    func stopDuringConfirmationPreventsFurtherReads() async throws {
        let gate = T2Gate()
        let device = T2Device()
        let controller = PurifierController(device: device, policy: T2Fixture.policy(attempts: 8))
        await controller.refreshNow()
        await device.configure(reads: [.gated(T2Fixture.state(), gate)])
        var finished = false
        let sending = Task {
            defer { finished = true }
            do { try await controller.send(.power(true)) }
            catch { /* The error type on stop is not defined by the contract. */ }
        }
        defer {
            controller.stop()
            sending.cancel()
            Task { await gate.open() }
        }
        try #require(await eventually { await device.snapshot().activeReads == 1 })
        controller.stop()
        let calls = await device.snapshot().calls
        await gate.open()
        try await Task.sleep(for: .milliseconds(450))
        #expect(await device.snapshot().calls == calls)
        #expect(finished)
    }

    @Test("stateUpdates delivers polls and read-backs to several subscribers and ends on stop")
    func streamsPublishConfirmedStatesAndFinish() async throws {
        let first = T2Fixture.state()
        let second = T2Fixture.state(pm25: 23)
        let confirmed = T2Fixture.state(isOn: true, pm25: 5)
        let device = T2Device(state: first)
        let controller = PurifierController(device: device, policy: T2Fixture.policy())
        let left = T2Updates()
        let right = T2Updates()
        let leftTask = collect(controller.stateUpdates(), into: left)
        let rightTask = collect(controller.stateUpdates(), into: right)
        defer {
            controller.stop()
            leftTask.cancel()
            rightTask.cancel()
        }
        await controller.refreshNow()
        try #require(await eventually {
            let l = await left.snapshot().states
            let r = await right.snapshot().states
            return l.contains(first) && r.contains(first)
        })
        await device.configure(fallback: second)
        await controller.refreshNow()
        try #require(await eventually {
            let l = await left.snapshot().states
            let r = await right.snapshot().states
            return l.contains(second) && r.contains(second)
        })
        await device.configure(reads: [.state(confirmed)], fallback: confirmed)
        try await controller.send(.power(true))
        try #require(await eventually {
            let l = await left.snapshot().states
            let r = await right.snapshot().states
            return l.contains(confirmed) && r.contains(confirmed)
        })
        controller.stop()
        try #require(await eventually {
            let l = await left.snapshot()
            let r = await right.snapshot()
            return l.finished && r.finished
        })
        for recorder in [left, right] {
            let states = await recorder.snapshot().states
            #expect(states.first == first)
            #expect(states.last == confirmed)
            let firstIndex = try #require(states.firstIndex(of: first))
            let secondIndex = try #require(states.firstIndex(of: second))
            let confirmedIndex = try #require(states.firstIndex(of: confirmed))
            #expect(firstIndex < secondIndex && secondIndex < confirmedIndex)
        }
    }
}
