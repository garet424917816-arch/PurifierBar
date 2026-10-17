// Protocol layer adapted from lightbar-direct (https://github.com/19s94/lightbar-direct), MIT License, Copyright (c) 2026 19s94.
import Foundation

/// MIoT property identifier in the form siid.piid.
public struct PropertyID: Hashable, Sendable, CustomStringConvertible {
    public let siid: Int
    public let piid: Int

    public init(siid: Int, piid: Int) {
        self.siid = siid
        self.piid = piid
    }

    public var description: String { "\(siid).\(piid)" }
}

/// MIoT property value: either a flag or an integer.
public enum MIoTValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
}

/// miIO protocol errors.
public enum MiIOError: Error, Sendable, Equatable {
    case invalidToken
    case badPacket
    case checksumMismatch
    case timeout
    case deviceError(code: Int)
    case propertyError(PropertyID, code: Int)
    case malformedReply
}
