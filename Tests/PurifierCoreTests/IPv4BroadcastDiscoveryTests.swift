import Darwin
import Testing
@testable import PurifierCore

private let broadcastFlags = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)

private func ipv4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
    (a << 24) | (b << 16) | (c << 8) | d
}

private func interfaceRecord(
    name: String = "en0",
    flags: UInt32 = broadcastFlags,
    address: UInt32 = ipv4(192, 168, 1, 40),
    netmask: UInt32 = ipv4(255, 255, 255, 0)
) -> IPv4BroadcastDiscovery.InterfaceRecord {
    .init(name: name, flags: flags, address: address, netmask: netmask)
}

@Test func directedBroadcastFor24BitSubnet() {
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: [interfaceRecord()]) == ["192.168.1.255"])
}

@Test func directedBroadcastFor16BitSubnet() {
    let record = interfaceRecord(address: ipv4(10, 42, 7, 9), netmask: ipv4(255, 255, 0, 0))
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: [record]) == ["10.42.255.255"])
}

@Test(arguments: [
    UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST | IFF_LOOPBACK),
    UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST | IFF_POINTOPOINT),
    UInt32(IFF_RUNNING | IFF_BROADCAST),
    UInt32(IFF_UP | IFF_BROADCAST),
    UInt32(IFF_UP | IFF_RUNNING),
])
func directedBroadcastSkipsIneligibleFlags(flags: UInt32) {
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: [interfaceRecord(flags: flags)]).isEmpty)
}

@Test(arguments: [ipv4(255, 255, 255, 254), ipv4(255, 255, 255, 255)])
func directedBroadcastSkipsSubnetsWithoutBroadcast(netmask: UInt32) {
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: [interfaceRecord(netmask: netmask)]).isEmpty)
}

@Test(arguments: [ipv4(169, 254, 0, 0), ipv4(169, 254, 42, 7), ipv4(169, 254, 255, 255)])
func directedBroadcastSkipsLinkLocalAddresses(address: UInt32) {
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: [interfaceRecord(address: address)]).isEmpty)
}

@Test func directedBroadcastDeduplicatesInterfacesInSameSubnet() {
    let records = [interfaceRecord(), interfaceRecord(name: "en1", address: ipv4(192, 168, 1, 41))]
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: records) == ["192.168.1.255"])
}

@Test func directedBroadcastOrderIsStableAcrossInterfaceEnumeration() {
    let records = [
        interfaceRecord(),
        interfaceRecord(name: "bridge0", address: ipv4(10, 42, 7, 9), netmask: ipv4(255, 255, 0, 0)),
        interfaceRecord(name: "en1", address: ipv4(192, 168, 9, 40)),
    ]
    let expected = ["10.42.255.255", "192.168.1.255", "192.168.9.255"]
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: records) == expected)
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: Array(records.reversed())) == expected)
}

@Test func helloBroadcastTargetsExcludeUnicastAndEndWithLimitedBroadcast() {
    let targets = IPv4BroadcastDiscovery.helloTargets(from: [interfaceRecord()])
    let knownHost = "192.168.1.191"
    #expect(!targets.contains(knownHost))
    #expect(targets == ["192.168.1.255", "255.255.255.255"])
}

@Test func helloUsesLimitedBroadcastWhenNoInterfaceIsEligible() {
    #expect(IPv4BroadcastDiscovery.broadcastAddresses(from: []).isEmpty)
    #expect(IPv4BroadcastDiscovery.helloTargets(from: []) == ["255.255.255.255"])
    let loopback = interfaceRecord(flags: broadcastFlags | UInt32(IFF_LOOPBACK))
    #expect(IPv4BroadcastDiscovery.helloTargets(from: [loopback]) == ["255.255.255.255"])
}

@Test func helloDoesNotRepeatLimitedBroadcastForZeroBitSubnet() {
    let records = [interfaceRecord(netmask: 0), interfaceRecord()]
    #expect(IPv4BroadcastDiscovery.helloTargets(from: records) == ["192.168.1.255", "255.255.255.255"])
}
