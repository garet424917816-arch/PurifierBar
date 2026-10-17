// Independent facts from the released MIoT specifications supplied for T17.
import Foundation
import Testing
@testable import PurifierCore

private struct LayoutFacts: Sendable {
    let layout: PurifierLayout
    // power, fault, mode, pm25, filter percent, hours, optional days,
    // sound, lock, screen, rpm, favorite level.
    let ids: [String]
    let maximum: Int
    let invertedScreen: Bool

    init(_ layout: PurifierLayout, _ ids: String, _ maximum: Int, invertedScreen: Bool = false) {
        self.layout = layout
        self.ids = ids.split(separator: " ").map(String.init)
        self.maximum = maximum
        self.invertedScreen = invertedScreen
    }

    var propertyIDs: [PropertyID] {
        ids.filter { $0 != "-" }.map(propertyID)
    }
}

private func propertyID(_ text: String) -> PropertyID {
    let parts = text.split(separator: ".").map { Int($0)! }
    return PropertyID(siid: parts[0], piid: parts[1])
}

private let layoutFacts: [LayoutFacts] = [
    .init(.cpa4, "2.1 2.2 2.4 3.4 4.1 4.3 4.4 6.1 8.1 13.2 9.1 9.11", 14),
    .init(.rma1, "2.1 2.2 2.4 3.4 4.1 4.3 4.4 6.1 8.1 13.2 9.1 9.2", 14),
    .init(.rma2, "2.1 2.2 2.4 3.4 4.1 4.3 4.4 5.1 6.1 7.2 8.1 11.1", 14),
    .init(.mb5, "2.1 2.2 2.4 3.4 4.1 4.3 4.4 6.1 8.1 13.2 9.1 9.5", 11),
    .init(.mb3, "2.2 2.1 2.5 3.6 4.3 4.5 - 5.1 7.1 6.1 10.8 10.10", 14, invertedScreen: true),
    .init(.proH, "2.2 2.1 2.5 3.6 4.3 4.5 - 5.1 7.1 6.1 10.8 10.10", 9, invertedScreen: true),
    .init(.za1, "2.1 2.2 2.5 3.6 4.3 4.5 - 5.1 7.1 6.1 10.11 10.10", 14, invertedScreen: true),
]

private actor LayoutTransport: MiIOTransport {
    private let reply: Data
    private(set) var calls: [(method: String, params: Data)] = []

    init(reply: Data) { self.reply = reply }

    func call(method: String, params: Data) async throws -> Data {
        calls.append((method, params))
        return reply
    }
}

private func readReply(_ facts: LayoutFacts, mode: Int = 2, fault: Int = 3, screen: Int = 0,
                       level: Int = 7) throws -> Data {
    let values: [Any] = [true, fault, mode, 149, 64, 100, 186, false, true, screen, 416, level]
    let rows: [[String: Any]] = zip(facts.ids, values).compactMap { text, value in
        guard text != "-" else { return nil }
        let id = propertyID(text)
        return ["siid": id.siid, "piid": id.piid, "code": 0, "value": value]
    }
    return try JSONSerialization.data(withJSONObject: ["result": rows])
}

private func purifier(_ transport: LayoutTransport, _ layout: PurifierLayout) -> MIoTPurifier {
    MIoTPurifier(client: MIoTClient(transport: transport, deviceID: "123456789"), layout: layout)
}

@Test(arguments: layoutFacts)
private func everyLayoutReadsItsOwnProperties(_ facts: LayoutFacts) async throws {
    let transport = LayoutTransport(reply: try readReply(facts))
    let state = try await purifier(transport, facts.layout).readState()
    let expected = PurifierState(
        isOn: true, fault: facts.layout == .mb5 ? .other(3) : .sensorLost,
        mode: .manual, pm25: 149, filterPercent: 64, filterHoursUsed: 100,
        filterDaysLeft: facts.ids[6] == "-" ? nil : 186,
        sound: false, childLock: true, screen: facts.invertedScreen ? .bright : .off,
        motorRPM: 416, favoriteLevel: 7
    )
    #expect(state == expected)
    let calls = await transport.calls
    #expect(calls.count == 1)
    #expect(calls[0].method == "get_properties")
    let rows = try #require(JSONSerialization.jsonObject(with: calls[0].params) as? [[String: Any]])
    let requested = try rows.map { row in
        PropertyID(siid: try #require(row["siid"] as? Int), piid: try #require(row["piid"] as? Int))
    }
    #expect(Set(requested) == Set(facts.propertyIDs))
    #expect(requested.count == facts.propertyIDs.count)
}

@Test(arguments: layoutFacts)
private func everyLayoutWritesAllCommands(_ facts: LayoutFacts) throws {
    let ids = facts.ids
    let commands: [(PurifierCommand, [String], [MIoTValue])] = [
        (.power(false), [ids[0]], [.bool(false)]),
        (.mode(.auto), [ids[2]], [.int(0)]),
        (.mode(.sleep), [ids[2]], [.int(1)]),
        (.mode(.manual), [ids[2]], [.int(2)]),
        (.favoriteLevel(7), [ids[11]], [.int(7)]),
        (.sound(true), [ids[7]], [.bool(true)]),
        (.childLock(false), [ids[8]], [.bool(false)]),
        (.screen(.off), [ids[9]], [.int(facts.invertedScreen ? 2 : 0)]),
        (.screen(.dim), [ids[9]], [.int(1)]),
        (.screen(.bright), [ids[9]], [.int(facts.invertedScreen ? 0 : 2)]),
        (.manualLevel(7), [ids[2], ids[11]], [.int(2), .int(7)]),
    ]
    for (command, expectedIDs, expectedValues) in commands {
        try command.validated(layout: facts.layout)
        let writes = command.writes(layout: facts.layout)
        #expect(writes.map(\.0) == expectedIDs.map(propertyID))
        #expect(writes.map(\.1) == expectedValues)
    }
}

@Test(arguments: layoutFacts)
private func everyLayoutValidatesLevelsBeforeNetwork(_ facts: LayoutFacts) async throws {
    let transport = LayoutTransport(reply: Data(#"{"result":[]}"#.utf8))
    let device = purifier(transport, facts.layout)
    #expect(facts.layout.favoriteLevelRange == 0...facts.maximum)
    for level in [-1, facts.maximum + 1, Int.max] {
        await #expect(throws: DeviceError.invalidValue) { try await device.apply(.favoriteLevel(level)) }
        await #expect(throws: DeviceError.invalidValue) { try await device.apply(.manualLevel(level)) }
    }
    #expect(await transport.calls.isEmpty)
    for level in [0, facts.maximum] {
        try await device.apply(.favoriteLevel(level))
        try await device.apply(.manualLevel(level))
        let readTransport = LayoutTransport(reply: try readReply(facts, level: level))
        #expect(try await purifier(readTransport, facts.layout).readState().favoriteLevel == level)
    }
    #expect(await transport.calls.count == 4)
    let invalidRead = LayoutTransport(reply: try readReply(facts, level: facts.maximum + 1))
    await #expect(throws: DeviceError.invalidValue) {
        _ = try await purifier(invalidRead, facts.layout).readState()
    }
}

@Test(arguments: layoutFacts)
private func everyLayoutPreservesUnknownModeAndMapsFaults(_ facts: LayoutFacts) async throws {
    for code in [0, 1, 2, 3, 4, 99] {
        let transport = LayoutTransport(reply: try readReply(facts, mode: 3, fault: code))
        let state = try await purifier(transport, facts.layout).readState()
        #expect(state.mode == nil)
        let expected: PurifierFault
        switch code {
        case 0: expected = .none
        case 2 where facts.layout != .mb5: expected = .motorStuck
        case 3 where facts.layout != .mb5: expected = .sensorLost
        default: expected = .other(code)
        }
        #expect(state.fault == expected)
    }
    for (value, brightness) in [(0, facts.invertedScreen ? ScreenBrightness.bright : .off),
                                (1, .dim), (2, facts.invertedScreen ? .off : .bright)] {
        let transport = LayoutTransport(reply: try readReply(facts, screen: value))
        #expect(try await purifier(transport, facts.layout).readState().screen == brightness)
    }
}

@Test(arguments: layoutFacts)
private func layoutPropertiesAreDistinctAndSafe(_ facts: LayoutFacts) {
    let ids = facts.layout.all
    #expect(Set(ids) == Set(facts.propertyIDs))
    #expect(Set(ids).count == ids.count)
    #expect(!ids.contains(PropertyID(siid: 9, piid: 10)))
    #expect(!ids.contains(PropertyID(siid: 9, piid: 12)))
}

@Test func modelTableMatchesIndependentFacts() {
    let expected: [String: PurifierLayout] = [
        "xiaomi.airp.cpa4": .cpa4, "xiaomi.airp.cpa4m": .cpa4,
        "zhimi.airp.cpa4": .cpa4, "zhimi.airp.rmb1": .cpa4,
        "zhimi.airpurifier.rma1": .rma1, "zhimi.airp.rma2": .rma2,
        "zhimi.airp.mb5": .mb5, "zhimi.airp.mb5a": .mb5,
        "zhimi.airp.mp4": .mb5, "zhimi.airp.mp4a": .mb5,
        "zhimi.airp.va2": .mb5, "zhimi.airp.va2a": .mb5, "zhimi.airp.vb4": .mb5,
        "zhimi.airpurifier.ma4": .mb3, "zhimi.airpurifier.mb3": .mb3, "zhimi.airp.mb3a": .mb3,
        "zhimi.airpurifier.va1": .proH, "zhimi.airpurifier.vb2": .proH,
        "zhimi.airpurifier.za1": .za1,
    ]
    #expect(SupportedModels.layouts == expected)
    #expect(SupportedModels.models == Set(expected.keys))
    for (model, layout) in expected {
        let decision = SupportedModels.decision(for: model, acceptedUnverifiedModel: nil)
        #expect(decision == .supported)
        #expect(SupportedModels.layout(for: model, decision: decision) == layout)
    }
}

@Test func layoutSelectionRequiresConsentAndFallsBackWithoutInfo() {
    for (model, accepted, expected): (String?, String?, PurifierLayout?) in [
        ("unknown.model", nil, nil),
        ("unknown.model", "other.model", nil),
        ("unknown.model", "unknown.model", .cpa4),
        (nil, nil, .cpa4),
        (nil, "unknown.model", .cpa4),
    ] {
        let decision = SupportedModels.decision(for: model, acceptedUnverifiedModel: accepted)
        #expect(SupportedModels.layout(for: model, decision: decision) == expected)
    }
}
