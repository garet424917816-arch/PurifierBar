// Protocol layer adapted from lightbar-direct (https://github.com/19s94/lightbar-direct), MIT License, Copyright (c) 2026 19s94.
import Foundation
import Darwin

/// Transport: one JSON request -> one JSON reply.
public protocol MiIOTransport: Sendable {
    /// `params` - a JSON array; returns the full JSON of the reply.
    func call(method: String, params: Data) async throws -> Data
}

/// miIO UDP transport to the purifier on the local network.
///
/// All mutable state is isolated on the private serial queue `queue`:
/// every read and write happens only inside work on this queue,
/// so the class is safe to pass between threads (`@unchecked Sendable`).
/// Blocking sockets run only on `queue`, not on the Swift cooperative pool.
public final class UDPTransport: MiIOTransport, @unchecked Sendable {
    private static let port: UInt16 = 54321
    private static let handshakeLifetime: TimeInterval = 120
    private static let callBudget: TimeInterval = 6
    /// How long the unicast phase of hello has for the known address, before broadcast is sent.
    private static let unicastLifetime: TimeInterval = 1

    private let queue = DispatchQueue(label: "PurifierBar.MiIO.UDPTransport")
    private let token: Data
    private let key: Data
    private let iv: Data

    private var host: String
    private var socketFD: Int32 = -1
    private var deviceID: UInt32?
    private var stamp: UInt32 = 0
    private var handshakeAt: Date?
    private var sequence = Int.random(in: 10000...500000)

    public init(host: String, token: Data) throws {
        guard token.count == 16 else { throw MiIOError.invalidToken }
        let derivedKey = Crypto.md5(token)
        self.token = token
        self.key = derivedKey
        self.iv = Crypto.md5(derivedKey + token)
        self.host = host
    }

    deinit {
        if socketFD >= 0 { Darwin.close(socketFD) }
    }

    /// The current device address; it may change after a broadcast search.
    public var currentHost: String { queue.sync { host } }

    /// Runs the hello handshake and returns the device id.
    public func resolveDeviceID() async throws -> UInt32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt32, Error>) in
            queue.async {
                do {
                    try self.ensureHandshake(deadline: Date().addingTimeInterval(3))
                    guard let deviceID = self.deviceID else { throw MiIOError.timeout }
                    continuation.resume(returning: deviceID)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func call(method: String, params: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try self.performCall(method: method, params: params))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Call (queue only)

    private func performCall(method: String, params: Data) throws -> Data {
        let hardDeadline = Date().addingTimeInterval(Self.callBudget)
        do {
            try ensureHandshake(deadline: min(Date().addingTimeInterval(2.5), hardDeadline))
            return try request(method: method, params: params,
                               deadline: min(Date().addingTimeInterval(2), hardDeadline))
        } catch MiIOError.invalidToken {
            throw MiIOError.invalidToken
        } catch MiIOError.checksumMismatch {
            throw MiIOError.checksumMismatch
        } catch {
            // Timeout or error: a fresh hello and one repeated request attempt
            // (covers the Mac sleeping, a device reboot, an IP change).
            try forceHandshake(deadline: min(Date().addingTimeInterval(2.5), hardDeadline))
            return try request(method: method, params: params, deadline: hardDeadline)
        }
    }

    private func ensureHandshake(deadline: Date) throws {
        if let at = handshakeAt, Date().timeIntervalSince(at) < Self.handshakeLifetime, deviceID != nil {
            return
        }
        try forceHandshake(deadline: deadline)
    }

    /// Sends hello to the known host by unicast, then to each interface's directed broadcast,
    /// then to the limited broadcast. All broadcast sends share one response deadline.
    private func forceHandshake(deadline: Date) throws {
        try openSocket()
        // The unicast phase has its own limit, otherwise it eats the whole budget and broadcast
        // is left no time (T13).
        // Without a known address (first launch) - straight to broadcast.
        if !host.isEmpty {
            try? send(MiIOCodec.hello, to: host)
            let unicastDeadline = Self.unicastDeadline(now: Date(), deadline: deadline)
            if waitForHello(deadline: unicastDeadline) { return }
            guard Date() < deadline else { throw MiIOError.timeout }
        }
        let targets = IPv4BroadcastDiscovery.helloTargets(from: IPv4BroadcastDiscovery.interfaceRecords())
        for target in targets {
            try? send(MiIOCodec.hello, to: target)
        }
        if waitForHello(deadline: deadline) { return }
        throw MiIOError.timeout
    }

    /// The limit of the hello unicast phase: not longer than `unicastLifetime`, but also not past
    /// the shared deadline. When the budget is less than that second, unicast takes all of it -
    /// broadcast will still not make it. A pure function - tested without a socket.
    static func unicastDeadline(now: Date, deadline: Date) -> Date {
        min(deadline, now.addingTimeInterval(unicastLifetime))
    }

    private func waitForHello(deadline: Date) -> Bool {
        while Date() < deadline {
            guard let (packet, ip) = receive(timeout: min(0.5, deadline.timeIntervalSinceNow)) else { continue }
            guard packet.count == 32, packet.integer(0..<2) == 0x2131, packet.integer(2..<4) == 32 else { continue }
            let id = UInt32(truncatingIfNeeded: packet.integer(4..<12))
            if let known = deviceID, id != known { continue }
            deviceID = id
            stamp = UInt32(truncatingIfNeeded: packet.integer(12..<16))
            host = ip
            handshakeAt = Date()
            return true
        }
        return false
    }

    private func request(method: String, params: Data, deadline: Date) throws -> Data {
        guard let deviceID else { throw MiIOError.timeout }
        sequence += 1
        let id = sequence
        guard let paramsObject = try? JSONSerialization.jsonObject(with: params) else {
            throw MiIOError.malformedReply
        }
        let payload: [String: Any] = ["id": id, "method": method, "params": paramsObject]
        guard let clear = try? JSONSerialization.data(withJSONObject: payload) else {
            throw MiIOError.malformedReply
        }
        let elapsed = UInt32(max(0, Date().timeIntervalSince(handshakeAt ?? Date())))
        let outgoing = try MiIOCodec.packet(json: clear, token: token, deviceID: deviceID, stamp: stamp &+ elapsed)
        try send(outgoing, to: host)

        while Date() < deadline {
            guard let (raw, ip) = receive(timeout: min(0.5, deadline.timeIntervalSinceNow)) else { continue }
            guard ip == host else { continue }
            let packet = Data(raw)
            guard packet.count > 32, packet.integer(0..<2) == 0x2131,
                  packet.integer(2..<4) == UInt64(packet.count) else { continue }
            // open() throws checksumMismatch - it is a foreign token, not a random packet.
            let opened = try MiIOCodec.open(packet, token: token)
            guard opened.deviceID == deviceID else { continue }
            guard let reply = try? JSONSerialization.jsonObject(with: opened.json) as? [String: Any],
                  reply["id"] as? Int == id else { continue }
            return opened.json
        }
        throw MiIOError.timeout
    }

    // MARK: - Socket (queue only)

    private func openSocket() throws {
        guard socketFD < 0 else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw MiIOError.timeout }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        socketFD = fd
    }

    private func address(_ ip: String) throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { throw MiIOError.badPacket }
        return addr
    }

    private func send(_ data: Data, to ip: String) throws {
        var addr = try address(ip)
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { throw MiIOError.timeout }
    }

    /// Reads one datagram waiting up to `timeout`. Returns nil on timeout
    /// or if the packet did not come from port 54321. The wait is held by the kernel
    /// (SO_RCVTIMEO), so the queue does not spin idle.
    private func receive(timeout: TimeInterval) -> (Data, String)? {
        guard socketFD >= 0 else { return nil }
        let microseconds = max(1, Int(max(0, timeout) * 1_000_000))
        var wait = timeval(tv_sec: microseconds / 1_000_000, tv_usec: Int32(microseconds % 1_000_000))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 8192)
        var addr = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(socketFD, &buffer, buffer.count, 0, $0, &size)
            }
        }
        guard count > 0, addr.sin_port == Self.port.bigEndian else { return nil }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        let ipBytes = ip.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return (Data(buffer.prefix(count)), String(decoding: ipBytes, as: UTF8.self))
    }
}
