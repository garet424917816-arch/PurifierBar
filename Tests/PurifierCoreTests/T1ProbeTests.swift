import CoreFoundation
import Foundation
import PurifierCore
import Testing

private enum ProbeVector {
    static let token = hex("00112233445566778899aabbccddeeff")
    static let plain = Data(#"{"id":42,"method":"get_properties","params":[{"did":"123456789","siid":2,"piid":1}]}"#.utf8)
    static let packet = hex("2131008000000000075bcd15000003e8f4a743f62f051e48b9fdc7768b9563fbbd6a2ee30f2a04a15abd54fee183e08783e8d9106f7f0105e5f301d0562da617a4a760dcf75cb4c53c34c54efb227f4b7f5653c51c45aac3ab8f77c2efcd9373fc7d6d94b666d379c383e6f4601adab95ffad8e22bb6a7219a5f28676ba31a3c")
    static let cipher = Data(packet.dropFirst(32))

    private static func hex(_ string: String) -> Data {
        let bytes = Array(string.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }
}

private actor ProbeTransport: MiIOTransport {
    struct Call: Sendable {
        let method: String
        let params: Data
    }

    private let reply: Data
    private var calls: [Call] = []

    init(reply: String) {
        self.reply = Data(reply.utf8)
    }

    func call(method: String, params: Data) async throws -> Data {
        calls.append(Call(method: method, params: params))
        return reply
    }

    func recordedCalls() -> [Call] { calls }
}

struct T1ProbeTests {
    @Test("packet matches the reference vector")
    func packetMatchesVector() throws {
        let packet = try MiIOCodec.packet(
            json: ProbeVector.plain, token: ProbeVector.token, deviceID: 123456789, stamp: 1000
        )
        #expect(packet == ProbeVector.packet)
    }

    @Test("open parses the reference vector")
    func openMatchesVector() throws {
        let opened = try MiIOCodec.open(ProbeVector.packet, token: ProbeVector.token)
        #expect(opened.deviceID == 123456789)
        #expect(opened.stamp == 1000)
        #expect(opened.json == ProbeVector.plain)
    }

    @Test("encrypt matches the ciphertext of the reference vector")
    func encryptMatchesVector() throws {
        #expect(try MiIOCodec.encrypt(ProbeVector.plain, token: ProbeVector.token) == ProbeVector.cipher)
    }

    @Test("decrypt returns the exact plaintext of the reference vector")
    func decryptMatchesVector() throws {
        #expect(try MiIOCodec.decrypt(ProbeVector.cipher, token: ProbeVector.token) == ProbeVector.plain)
    }

    @Test("decrypt strips trailing zero bytes")
    func decryptStripsTrailingZeros() throws {
        let cipher = try MiIOCodec.encrypt(ProbeVector.plain + Data([0, 0]), token: ProbeVector.token)
        #expect(try MiIOCodec.decrypt(cipher, token: ProbeVector.token) == ProbeVector.plain)
    }

    @Test("hello has the exact format of the contract")
    func helloMatchesContract() {
        #expect(MiIOCodec.hello == Data([0x21, 0x31, 0x00, 0x20] + Array(repeating: 0xff, count: 28)))
    }

    @Test("open rejects a foreign token")
    func openRejectsWrongToken() {
        // A foreign token is obtained by changing only the test token.
        var wrongToken = ProbeVector.token
        wrongToken[0] ^= 1
        #expect(throws: MiIOError.checksumMismatch) {
            try MiIOCodec.open(ProbeVector.packet, token: wrongToken)
        }
    }

    @Test("open rejects a truncated packet", arguments: [0, 3, 16, 31, 32, 127])
    func openRejectsTruncation(length: Int) {
        #expect(throws: MiIOError.badPacket) {
            try MiIOCodec.open(Data(ProbeVector.packet.prefix(length)), token: ProbeVector.token)
        }
    }

    @Test("open rejects a wrong magic", arguments: [0, 1])
    func openRejectsBadMagic(index: Int) {
        var packet = ProbeVector.packet
        packet[index] ^= 1
        #expect(throws: MiIOError.badPacket) {
            try MiIOCodec.open(packet, token: ProbeVector.token)
        }
    }

    @Test("codec rejects a token that is not 16 bytes", arguments: [0, 15, 17])
    func codecRejectsInvalidToken(length: Int) {
        let token = Data((ProbeVector.token + Data([0])).prefix(length))
        #expect(throws: MiIOError.invalidToken) {
            try MiIOCodec.encrypt(ProbeVector.plain, token: token)
        }
        #expect(throws: MiIOError.invalidToken) {
            try MiIOCodec.decrypt(ProbeVector.cipher, token: token)
        }
        #expect(throws: MiIOError.invalidToken) {
            try MiIOCodec.packet(json: ProbeVector.plain, token: token, deviceID: 123456789, stamp: 1000)
        }
        #expect(throws: MiIOError.invalidToken) {
            try MiIOCodec.open(ProbeVector.packet, token: token)
        }
    }

    @Test("get sends did as a string and siid/piid without value")
    func getRequestFormat() async throws {
        let transport = ProbeTransport(reply: #"{"result":[{"siid":2,"piid":1,"code":0,"value":true},{"siid":3,"piid":4,"code":0,"value":17}]}"#)
        let client = MIoTClient(transport: transport, deviceID: "00123456789")
        let ids = [PropertyID(siid: 2, piid: 1), PropertyID(siid: 3, piid: 4)]
        _ = try await client.get(ids)
        let calls = await transport.recordedCalls()
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.method == "get_properties")
        let rows = try parameterRows(call.params)
        #expect(rows.count == ids.count)
        var found: Set<PropertyID> = []
        for row in rows {
            #expect(Set(row.keys) == Set(["did", "siid", "piid"]))
            #expect(row["did"] as? String == "00123456789")
            let id = try propertyID(row)
            #expect(ids.contains(id))
            found.insert(id)
        }
        #expect(found == Set(ids))
    }

    @Test("get distinguishes bool and int and matches results by PropertyID")
    func getParsesMixedValues() async throws {
        let transport = ProbeTransport(reply: #"{"result":[{"siid":3,"piid":1,"code":0,"value":1},{"siid":2,"piid":2,"code":0,"value":false},{"siid":3,"piid":2,"code":0,"value":0},{"siid":2,"piid":1,"code":0,"value":true},{"siid":3,"piid":3,"code":0,"value":-17}]}"#)
        let client = MIoTClient(transport: transport, deviceID: "123456789")
        let expected: [PropertyID: MIoTValue] = [
            PropertyID(siid: 2, piid: 1): .bool(true),
            PropertyID(siid: 2, piid: 2): .bool(false),
            PropertyID(siid: 3, piid: 1): .int(1),
            PropertyID(siid: 3, piid: 2): .int(0),
            PropertyID(siid: 3, piid: 3): .int(-17),
        ]
        let ids = [PropertyID(siid: 2, piid: 1), PropertyID(siid: 2, piid: 2),
                   PropertyID(siid: 3, piid: 1), PropertyID(siid: 3, piid: 2), PropertyID(siid: 3, piid: 3)]
        #expect(try await client.get(ids) == expected)
    }

    @Test("set sends did as a string, siid/piid and the typed value")
    func setRequestFormat() async throws {
        let transport = ProbeTransport(reply: #"{"result":[{"siid":2,"piid":1,"code":0},{"siid":2,"piid":2,"code":0},{"siid":3,"piid":1,"code":0},{"siid":3,"piid":2,"code":0}]}"#)
        let client = MIoTClient(transport: transport, deviceID: "00123456789")
        let values: [(PropertyID, MIoTValue)] = [
            (PropertyID(siid: 2, piid: 1), .bool(true)),
            (PropertyID(siid: 2, piid: 2), .bool(false)),
            (PropertyID(siid: 3, piid: 1), .int(1)),
            (PropertyID(siid: 3, piid: 2), .int(-17)),
        ]
        try await client.set(values)
        let calls = await transport.recordedCalls()
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.method == "set_properties")
        let rows = try parameterRows(call.params)
        #expect(rows.count == values.count)
        let expected = Dictionary(uniqueKeysWithValues: values)
        var found: Set<PropertyID> = []
        for row in rows {
            #expect(Set(row.keys) == Set(["did", "siid", "piid", "value"]))
            #expect(row["did"] as? String == "00123456789")
            let id = try propertyID(row)
            let value = try #require(row["value"] as? NSNumber)
            let expectedValue = try #require(expected[id])
            switch expectedValue {
            case .bool(let bool):
                #expect(CFGetTypeID(value) == CFBooleanGetTypeID())
                #expect(value.boolValue == bool)
            case .int(let int):
                #expect(CFGetTypeID(value) != CFBooleanGetTypeID())
                #expect(value.doubleValue == Double(int))
            }
            found.insert(id)
        }
        #expect(found == Set(expected.keys))
    }

    @Test("code != 0 returns propertyError with the ID of the failing line", arguments: [false, true])
    func propertyErrorIdentifiesFailedRow(isSet: Bool) async {
        let transport = ProbeTransport(reply: #"{"result":[{"siid":2,"piid":1,"code":0,"value":true},{"siid":3,"piid":4,"code":-704042000}]}"#)
        let client = MIoTClient(transport: transport, deviceID: "123456789")
        let good = PropertyID(siid: 2, piid: 1)
        let bad = PropertyID(siid: 3, piid: 4)
        await #expect(throws: MiIOError.propertyError(bad, code: -704042000)) {
            if isSet {
                try await client.set([(bad, .int(7)), (good, .bool(true))])
            } else {
                _ = try await client.get([bad, good])
            }
        }
    }

    @Test("error field returns deviceError", arguments: [0, 1, 2])
    func replyErrorBecomesDeviceError(operation: Int) async {
        let transport = ProbeTransport(reply: #"{"error":{"code":-32601,"message":"Невідомий метод"}}"#)
        let client = MIoTClient(transport: transport, deviceID: "123456789")
        await #expect(throws: MiIOError.deviceError(code: -32601)) {
            switch operation {
            case 0: _ = try await client.get([PropertyID(siid: 2, piid: 1)])
            case 1: try await client.set([(PropertyID(siid: 2, piid: 1), .bool(true))])
            default: try await client.action(siid: 2, aiid: 1)
            }
        }
    }

    @Test("reply without result returns malformedReply", arguments: [0, 1, 2])
    func missingResultIsMalformed(operation: Int) async {
        let transport = ProbeTransport(reply: #"{"id":42}"#)
        let client = MIoTClient(transport: transport, deviceID: "123456789")
        await #expect(throws: MiIOError.malformedReply) {
            switch operation {
            case 0: _ = try await client.get([PropertyID(siid: 2, piid: 1)])
            case 1: try await client.set([(PropertyID(siid: 2, piid: 1), .bool(true))])
            default: try await client.action(siid: 2, aiid: 1)
            }
        }
    }

    @Test("PropertyID.description has the siid.piid format")
    func propertyDescription() {
        #expect(PropertyID(siid: 2, piid: 4).description == "2.4")
    }

    private func parameterRows(_ data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)
        return try #require(json as? [[String: Any]])
    }

    private func propertyID(_ row: [String: Any]) throws -> PropertyID {
        let siid = try #require(row["siid"] as? NSNumber)
        let piid = try #require(row["piid"] as? NSNumber)
        #expect(CFGetTypeID(siid) != CFBooleanGetTypeID())
        #expect(CFGetTypeID(piid) != CFBooleanGetTypeID())
        #expect(siid.doubleValue == Double(siid.intValue))
        #expect(piid.doubleValue == Double(piid.intValue))
        return PropertyID(siid: siid.intValue, piid: piid.intValue)
    }
}
