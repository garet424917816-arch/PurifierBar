// Tests of the miIO protocol layer: reference vector, cryptography, parsing of replies.
import Foundation
import Testing
@testable import PurifierCore

/// Test token from the contract (not a real one).
private let testToken = Data(hex: "00112233445566778899aabbccddeeff")!
private let testDeviceID = 123456789

/// Fake transport: returns pre-prepared replies and remembers the calls.
private actor FakeTransport: MiIOTransport {
    private var replies: [Data]
    private var calls: [(method: String, params: Data)] = []

    init(replies: [Data]) { self.replies = replies }

    func call(method: String, params: Data) async throws -> Data {
        calls.append((method, params))
        return replies.removeFirst()
    }

    func recordedCalls() -> [(method: String, params: Data)] { calls }
}

private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

// MARK: - Optional model information

@Test func infoReturnsModelAndUsesExistingTransport() async throws {
    let transport = FakeTransport(replies: [try json(["result": ["model": "xiaomi.airp.cpa4"]])])
    let client = MIoTClient(transport: transport, deviceID: "123456789")
    #expect(try await client.model() == "xiaomi.airp.cpa4")
    let calls = await transport.recordedCalls()
    #expect(calls.count == 1)
    #expect(calls[0].method == "miIO.info")
    #expect(try (JSONSerialization.jsonObject(with: calls[0].params) as? [String]) == [])
}

@Test(arguments: [
    #"{"result":{}}"#, #"{}"#, #"{"result":{"model":42}}"#,
    #"{"result":{"model":true}}"#, #"{"result":{"model":null}}"#,
    #"{"result":[]}"#, #"{"result":{"model":[]}}"#,
])
func infoWithoutStringModelIsOptional(reply: String) async throws {
    let client = MIoTClient(transport: FakeTransport(replies: [Data(reply.utf8)]), deviceID: "123456789")
    #expect(try await client.model() == nil)
}

@Test func infoPropagatesDeviceErrorForCallerFallback() async throws {
    let reply = try json(["error": ["code": -1]])
    let client = MIoTClient(transport: FakeTransport(replies: [reply]), deviceID: "123456789")
    await #expect(throws: MiIOError.deviceError(code: -1)) { try await client.model() }
}

@Test func modelDecisionRequiresConsentForExactUnverifiedModel() {
    let supported: Set<String> = ["xiaomi.airp.cpa4"]
    func decision(_ model: String?, accepted: String? = nil) -> SupportedModels.Decision {
        SupportedModels.decision(for: model, supported: supported, acceptedUnverifiedModel: accepted)
    }

    #expect(decision("xiaomi.airp.cpa4") == .supported)
    #expect(decision("xiaomi.airp.cpa4", accepted: "other.model") == .supported)
    #expect(decision("other.model") == .needsConfirmation)
    #expect(decision("other.model", accepted: "other.model") == .acceptedUnverified)
    #expect(decision("other.model", accepted: "previous.model") == .needsConfirmation)
    #expect(decision(nil) == .supported)
    #expect(decision(nil, accepted: "other.model") == .supported)
    #expect(decision("XIAOMI.AIRP.CPA4") == .needsConfirmation)
    #expect(decision("") == .needsConfirmation)
    #expect(SupportedModels.decision(
        for: "custom.model", supported: ["custom.model"], acceptedUnverifiedModel: nil
    ) == .supported)
}

// MARK: - Reference vector

@Test func referenceVector() throws {
    let plain = Data(#"{"id":42,"method":"get_properties","params":[{"did":"123456789","siid":2,"piid":1}]}"#.utf8)
    let expected = Data(hex: "2131008000000000075bcd15000003e8f4a743f62f051e48b9fdc7768b9563fbbd6a2ee30f2a04a15abd54fee183e08783e8d9106f7f0105e5f301d0562da617a4a760dcf75cb4c53c34c54efb227f4b7f5653c51c45aac3ab8f77c2efcd9373fc7d6d94b666d379c383e6f4601adab95ffad8e22bb6a7219a5f28676ba31a3c")!

    let packet = try MiIOCodec.packet(json: plain, token: testToken, deviceID: UInt32(testDeviceID), stamp: 1000)
    #expect(packet == expected)

    let opened = try MiIOCodec.open(packet, token: testToken)
    #expect(opened.deviceID == UInt32(testDeviceID))
    #expect(opened.stamp == 1000)
    #expect(opened.json == plain)
}

@Test func derivedKeyAndIV() {
    #expect(Crypto.md5(testToken) == Data(hex: "6e8311168ee16d6aa1aa48c64145003c"))
    let key = Data(hex: "6e8311168ee16d6aa1aa48c64145003c")!
    #expect(Crypto.md5(key + testToken) == Data(hex: "6f434fa9acd75da73e5fb999f641cda2"))
}

@Test func helloConstant() {
    #expect(MiIOCodec.hello.count == 32)
    #expect(MiIOCodec.hello == Data([UInt8]([0x21, 0x31, 0x00, 0x20]) + [UInt8](repeating: 0xff, count: 28)))
}

// MARK: - Handshake phases

@Test func unicastPhaseGetsOwnBudgetWithinLongDeadline() {
    // Budgets of 3 s (resolveDeviceID) and 2.5 s (retry): unicast does not eat all the time,
    // so broadcast gets a chance too.
    let now = Date()
    for budget in [3.0, 2.5] {
        let deadline = now.addingTimeInterval(budget)
        #expect(UDPTransport.unicastDeadline(now: now, deadline: deadline) < deadline)
    }
}

@Test func unicastPhaseNeverExceedsDeadline() {
    // A budget shorter than a second: unicast takes all of it - broadcast will not make it.
    let now = Date()
    for budget in [0.9, 0.5, 0.0] {
        let deadline = now.addingTimeInterval(budget)
        #expect(UDPTransport.unicastDeadline(now: now, deadline: deadline) == deadline)
    }
}

// MARK: - Failures

@Test func invalidTokenLength() {
    #expect(throws: MiIOError.invalidToken) {
        _ = try MiIOCodec.encrypt(Data("{}".utf8), token: Data([0x01, 0x02]))
    }
    #expect(throws: MiIOError.invalidToken) {
        _ = try UDPTransport(host: "127.0.0.1", token: Data([0x01, 0x02]))
    }
}

@Test func wrongTokenIsRejected() throws {
    let packet = try MiIOCodec.packet(json: Data(#"{"id":1}"#.utf8), token: testToken,
                                      deviceID: 1, stamp: 2)
    var other = testToken
    other[0] ^= 0xff
    #expect(throws: MiIOError.checksumMismatch) {
        _ = try MiIOCodec.open(packet, token: other)
    }
}

@Test func truncatedPacketIsRejected() {
    #expect(throws: MiIOError.badPacket) {
        _ = try MiIOCodec.open(Data(repeating: 0x21, count: 8), token: testToken)
    }
}

@Test func encryptionRoundTrip() throws {
    let plain = Data(#"{"id":7,"result":[{"value":18}]}"#.utf8)
    let cipher = try MiIOCodec.encrypt(plain, token: testToken)
    #expect(cipher.count % 16 == 0)
    #expect(cipher.count > plain.count)
    #expect(try MiIOCodec.decrypt(cipher, token: testToken) == plain)
}

@Test func propertyDescription() {
    #expect(PropertyID(siid: 2, piid: 4).description == "2.4")
}

// MARK: - Parsing MIoTClient replies

@Test func getParsesMixedBoolAndInt() async throws {
    let reply = try json(["id": 1, "result": [
        ["did": "123456789", "siid": 2, "piid": 1, "code": 0, "value": true],
        ["did": "123456789", "siid": 3, "piid": 4, "code": 0, "value": 18],
        ["did": "123456789", "siid": 9, "piid": 11, "code": 0, "value": 0],
    ]])
    let transport = FakeTransport(replies: [reply])
    let client = MIoTClient(transport: transport, deviceID: "123456789")

    let values = try await client.get([
        PropertyID(siid: 2, piid: 1),
        PropertyID(siid: 3, piid: 4),
        PropertyID(siid: 9, piid: 11),
    ])

    #expect(values[PropertyID(siid: 2, piid: 1)] == .bool(true))
    #expect(values[PropertyID(siid: 3, piid: 4)] == .int(18))
    #expect(values[PropertyID(siid: 9, piid: 11)] == .int(0))

    let calls = await transport.recordedCalls()
    #expect(calls.count == 1)
    #expect(calls[0].method == "get_properties")
}

@Test func getSendsDeviceIDAndPropertyIDs() async throws {
    let reply = try json(["id": 1, "result": [["siid": 2, "piid": 1, "code": 0, "value": false]]])
    let transport = FakeTransport(replies: [reply])
    let client = MIoTClient(transport: transport, deviceID: "123456789")

    _ = try await client.get([PropertyID(siid: 2, piid: 1), PropertyID(siid: 6, piid: 1)])

    let calls = await transport.recordedCalls()
    let params = try JSONSerialization.jsonObject(with: calls[0].params) as? [[String: Any]]
    #expect(params?.count == 2)
    #expect(params?[0]["did"] as? String == "123456789")
    #expect(params?[0]["siid"] as? Int == 2)
    #expect(params?[0]["piid"] as? Int == 1)
    #expect(params?[1]["siid"] as? Int == 6)
}

@Test func getReportsPropertyError() async throws {
    let reply = try json(["id": 1, "result": [
        ["did": "123456789", "siid": 2, "piid": 2, "code": 5],
    ]])
    let transport = FakeTransport(replies: [reply])
    let client = MIoTClient(transport: transport, deviceID: "123456789")

    await #expect(throws: MiIOError.propertyError(PropertyID(siid: 2, piid: 2), code: 5)) {
        _ = try await client.get([PropertyID(siid: 2, piid: 2)])
    }
}

@Test func getReportsDeviceError() async throws {
    let reply = try json(["id": 1, "error": ["code": -1, "message": "не підтримується"]])
    let transport = FakeTransport(replies: [reply])
    let client = MIoTClient(transport: transport, deviceID: "123456789")

    await #expect(throws: MiIOError.deviceError(code: -1)) {
        _ = try await client.get([PropertyID(siid: 2, piid: 3)])
    }
}

@Test func malformedReplyWithoutResult() async throws {
    let reply = try json(["id": 1])
    let transport = FakeTransport(replies: [reply])
    let client = MIoTClient(transport: transport, deviceID: "123456789")

    await #expect(throws: MiIOError.malformedReply) {
        _ = try await client.get([PropertyID(siid: 2, piid: 1)])
    }
}

@Test func setSendsValuesAndAcceptsSuccess() async throws {
    let reply = try json(["id": 1, "result": [
        ["did": "123456789", "siid": 6, "piid": 1, "code": 0],
    ]])
    let transport = FakeTransport(replies: [reply])
    let client = MIoTClient(transport: transport, deviceID: "123456789")

    try await client.set([(PropertyID(siid: 6, piid: 1), .bool(false))])

    let calls = await transport.recordedCalls()
    #expect(calls[0].method == "set_properties")
    let params = try JSONSerialization.jsonObject(with: calls[0].params) as? [[String: Any]]
    #expect(params?[0]["value"] as? Bool == false)
    #expect(params?[0]["siid"] as? Int == 6)
}

@Test func setReportsPropertyError() async throws {
    let reply = try json(["id": 1, "result": [
        ["did": "123456789", "siid": 9, "piid": 11, "code": 3],
    ]])
    let transport = FakeTransport(replies: [reply])
    let client = MIoTClient(transport: transport, deviceID: "123456789")

    await #expect(throws: MiIOError.propertyError(PropertyID(siid: 9, piid: 11), code: 3)) {
        try await client.set([(PropertyID(siid: 9, piid: 11), .int(20))])
    }
}

@Test func actionSuccessAndFailure() async throws {
    let ok = try json(["id": 1, "result": ["code": 0]])
    let bad = try json(["id": 1, "result": ["code": 2, "out": []]])

    let successTransport = FakeTransport(replies: [ok])
    try await MIoTClient(transport: successTransport, deviceID: "123456789").action(siid: 2, aiid: 1)
    let calls = await successTransport.recordedCalls()
    #expect(calls[0].method == "action")
    let params = try JSONSerialization.jsonObject(with: calls[0].params) as? [[String: Any]]
    #expect(params?[0]["aiid"] as? Int == 1)

    let failureTransport = FakeTransport(replies: [bad])
    await #expect(throws: MiIOError.deviceError(code: 2)) {
        try await MIoTClient(transport: failureTransport, deviceID: "123456789").action(siid: 2, aiid: 1)
    }
}
