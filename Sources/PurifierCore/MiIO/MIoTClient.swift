// Protocol layer adapted from lightbar-direct (https://github.com/19s94/lightbar-direct), MIT License, Copyright (c) 2026 19s94.
import Foundation
import CoreFoundation

/// MIoT client: get_properties / set_properties / action through the transport.
public actor MIoTClient {
    private let transport: MiIOTransport
    private let deviceID: String

    /// `deviceID` - the did as a string, as in JSON (for example "123456789").
    public init(transport: MiIOTransport, deviceID: String) {
        self.transport = transport
        self.deviceID = deviceID
    }

    /// Reads properties. An empty dictionary if the device returned nothing.
    public func get(_ ids: [PropertyID]) async throws -> [PropertyID: MIoTValue] {
        let params = ids.map { ["did": deviceID, "siid": $0.siid, "piid": $0.piid] as [String: Any] }
        let rows = try await resultRows(method: "get_properties", params: params)
        var values: [PropertyID: MIoTValue] = [:]
        for row in rows {
            let id = try propertyID(row)
            let code = try code(row)
            if code != 0 { throw MiIOError.propertyError(id, code: code) }
            guard let value = Self.value(row["value"]) else { throw MiIOError.malformedReply }
            values[id] = value
        }
        return values
    }

    /// Writes properties. Each reply line has code == 0.
    public func set(_ values: [(PropertyID, MIoTValue)]) async throws {
        let params = values.map { id, value -> [String: Any] in
            ["did": deviceID, "siid": id.siid, "piid": id.piid, "value": Self.json(value)]
        }
        let rows = try await resultRows(method: "set_properties", params: params)
        for row in rows {
            let id = try propertyID(row)
            let code = try code(row)
            if code != 0 { throw MiIOError.propertyError(id, code: code) }
        }
    }

    /// Calls a MIoT action (siid.aiid).
    public func action(siid: Int, aiid: Int) async throws {
        let params: [[String: Any]] = [["did": deviceID, "siid": siid, "aiid": aiid]]
        let reply = try await request(method: "action", params: params)
        guard let result = reply["result"] as? [String: Any], let code = result["code"] as? Int else {
            throw MiIOError.malformedReply
        }
        if code != 0 { throw MiIOError.deviceError(code: code) }
    }

    // MARK: - Parsing replies

    /// Optional model information, using the same authenticated transport as property reads.
    public func model() async throws -> String? {
        let reply = try await request(method: "miIO.info", params: [])
        return (reply["result"] as? [String: Any])?["model"] as? String
    }

    private func request(method: String, params: [[String: Any]]) async throws -> [String: Any] {
        guard let paramsData = try? JSONSerialization.data(withJSONObject: params) else {
            throw MiIOError.malformedReply
        }
        let replyData = try await transport.call(method: method, params: paramsData)
        guard let reply = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any] else {
            throw MiIOError.malformedReply
        }
        if let error = reply["error"] as? [String: Any] {
            throw MiIOError.deviceError(code: error["code"] as? Int ?? -1)
        }
        return reply
    }

    private func resultRows(method: String, params: [[String: Any]]) async throws -> [[String: Any]] {
        let reply = try await request(method: method, params: params)
        guard let rows = reply["result"] as? [[String: Any]] else { throw MiIOError.malformedReply }
        return rows
    }

    private func propertyID(_ row: [String: Any]) throws -> PropertyID {
        guard let siid = row["siid"] as? Int, let piid = row["piid"] as? Int else {
            throw MiIOError.malformedReply
        }
        return PropertyID(siid: siid, piid: piid)
    }

    private func code(_ row: [String: Any]) throws -> Int {
        guard let code = row["code"] as? Int else { throw MiIOError.malformedReply }
        return code
    }

    private static func value(_ any: Any?) -> MIoTValue? {
        guard let any else { return nil }
        if let number = any as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        if let int = any as? Int { return .int(int) }
        return nil
    }

    private static func json(_ value: MIoTValue) -> Any {
        switch value {
        case .bool(let flag): return flag
        case .int(let number): return number
        }
    }
}
