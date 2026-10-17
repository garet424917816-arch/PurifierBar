import Darwin

enum IPv4BroadcastDiscovery {
    /// IPv4 address and netmask are integers in host byte order.
    struct InterfaceRecord: Sendable {
        let name: String
        let flags: UInt32
        let address: UInt32
        let netmask: UInt32
    }

    /// Copies IPv4 records only; interface eligibility is decided by the pure function below.
    /// Called on the transport queue during a fresh handshake, never for individual requests.
    static func interfaceRecords() -> [InterfaceRecord] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var records: [InterfaceRecord] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let addressBits = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmaskBits = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            records.append(InterfaceRecord(name: String(cString: entry.ifa_name), flags: entry.ifa_flags,
                                           address: addressBits, netmask: netmaskBits))
        }
        return records
    }

    /// Returns unique directed broadcasts in numeric order, independent of interface enumeration order.
    static func broadcastAddresses(from records: [InterfaceRecord]) -> [String] {
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let excluded = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        var broadcasts: Set<UInt32> = []
        for record in records {
            guard record.flags & required == required, record.flags & excluded == 0,
                  record.netmask.nonzeroBitCount < 31,
                  record.address & 0xffff0000 != 0xa9fe0000 else { continue }
            broadcasts.insert(record.address | ~record.netmask)
        }
        return broadcasts.sorted().map { address in
            [24, 16, 8, 0].map { String((address >> $0) & 0xff) }.joined(separator: ".")
        }
    }

    /// The limited broadcast is always the final fallback, even if an interface has a /0 mask.
    static func helloTargets(from records: [InterfaceRecord]) -> [String] {
        let limitedBroadcast = "255.255.255.255"
        return broadcastAddresses(from: records).filter { $0 != limitedBroadcast } + [limitedBroadcast]
    }
}
