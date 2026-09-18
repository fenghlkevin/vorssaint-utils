// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

final class FakeTunnelNetwork: ProxyTunnelNetwork {
    var rows = [ProxyRoute(prefix: try! ProxyCIDR("0.0.0.0/0"), gateway: "192.168.1.1", interface: "en0"), ProxyRoute(prefix: try! ProxyCIDR("192.168.1.0/24"), gateway: "link#1", interface: "en0"), ProxyRoute(prefix: try! ProxyCIDR("172.27.0.0/16"), gateway: "10.8.0.1", interface: "utun2")]
    var ours = true
    var additions = 0
    var failAt: Int?
    var removedForeign = false
    var closed = false
    let identity = ProxyTunnelIdentity(name: "utun9", index: 42, ipv4: "198.18.7.1", ipv6: nil)
    func snapshot(excluding: String?) throws -> ProxyNetworkSnapshot { .init(routes: rows.filter { $0.interface != excluding }) }
    func create(ipv6: Bool) throws -> (ProxyTunnelIdentity, Int32) { ours = true; return (identity, 99) }
    func owns(_ identity: ProxyTunnelIdentity) -> Bool { ours && identity == self.identity }
    func add(_ route: ProxyCIDR, to identity: ProxyTunnelIdentity) throws {
        additions += 1
        if additions == failAt { throw ProxyTunnelError(message: "simulated route failure") }
        rows.append(.init(prefix: route, gateway: "link#42", interface: identity.name))
    }
    func remove(_ route: ProxyCIDR, from identity: ProxyTunnelIdentity) throws {
        rows.removeAll { $0.prefix == route && $0.interface == identity.name }
    }
    func close(_ descriptor: Int32, identity: ProxyTunnelIdentity) { closed = true }
}
@main struct ProxyTunnelTests {
    static func check(_ value: @autoclosure () -> Bool, _ text: String) { precondition(value(), text) }
    static func main() throws {
        let network = FakeTunnelNetwork()
        let original = network.rows
        let snapshot = ProxyNetworkSnapshot(routes: original)
        let plan = ProxyTunnelPlan(ipv6: false, exclusions: ["121.36.94.175/32", "203.0.113.2/32"])
        let routes = try plan.routes(snapshot: snapshot)
        for excluded in ["172.27.199.177", "10.1.1.1", "192.168.1.3", "121.36.94.175", "203.0.113.2", "127.0.0.1"] {
            let target = try ProxyCIDR(excluded)
            check(!routes.contains { $0.contains(target) }, "protected destination captured")
        }
        check(routes.contains { $0.contains(try! ProxyCIDR("8.8.8.8")) }, "public route missing")
        let a = try ProxyCIDR("2001:db8::/32"), b = try ProxyCIDR("2001:db8:1::/48")
        check(a.subtract(b).allSatisfy { !$0.contains(b) }, "IPv6 subtraction")
        let full = ProxyNetworkSnapshot(routes: original + [.init(prefix: try ProxyCIDR("0.0.0.0/1"), gateway: "10.8.0.1", interface: "utun2")])
        do { _ = try plan.routes(snapshot: full); fatalError("full VPN not blocked") } catch {}
        let v6Snapshot = ProxyNetworkSnapshot(routes: original + [.init(prefix: try ProxyCIDR("::/0"), gateway: "fe80::1", interface: "en0")])
        let v6 = try ProxyTunnelPlan(ipv6: true).routes(snapshot: v6Snapshot)
        check(v6.contains { $0.contains(try! ProxyCIDR("2606:4700:4700::1111")) }, "IPv6 public capture missing")
        check(!v6.contains { $0.contains(try! ProxyCIDR("fd00::123")) }, "IPv6 private captured")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("journal.json")
        let lease = ProxyTunnelLease(backend: network, journal: journal)
        try lease.prepare(plan); try lease.activate(); check(lease.active, "activation failed")
        network.rows.append(.init(prefix: try ProxyCIDR("10.22.0.0/16"), gateway: "10.8.0.1", interface: "utun3"))
        do { try lease.checkNetwork(); fatalError("VPN change not detected") } catch {}
        check(!lease.active && network.closed, "network change did not suspend")
        check(network.rows.contains(original[2]), "foreign VPN route removed")
        network.rows = original; network.additions = 0; network.failAt = 3
        try lease.prepare(plan)
        do { try lease.activate(); fatalError("partial failure ignored") } catch {}
        check(network.rows == original, "partial route rollback incomplete")
        network.failAt = nil; network.additions = 0
        try lease.prepare(plan); try lease.activate()
        let recovery = ProxyTunnelLease(backend: network, journal: journal)
        try recovery.recover(); check(network.rows == original, "crash recovery failed")
        try lease.restore()
        let parsed = ProxyNetworkSnapshot.parse("Destination Gateway Flags Netif Expire\n10/8 10.8.0.1 UGSc utun2\ndefault 192.168.1.1 UGScg en0\n192.168.1.2 aa:bb UHLWI en0", ipv6: false)
        check(parsed.count == 2 && parsed[0].prefix.description == "10.0.0.0/8", "netstat parser")
        let query = try ProxyCompanyDiagnostics.dnsQuery("git.example.test")
        let id = Array(query.dropFirst(2).prefix(2))
        let response = Data(id + [0x81, 0x80, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 10, 2, 3, 4])
        let answer = try ProxyCompanyDiagnostics.dnsAnswers(response, identifier: id)
        check(answer == ["10.2.3.4"], "DNS answer decoding")
        do { _ = try ProxyCompanyDiagnostics.dnsAnswers(Data(response.prefix(15)), identifier: id); fatalError("truncated DNS accepted") } catch {}
        do { _ = try JSONDecoder().decode(ProxyCIDR.self, from: Data("{\"bytes\":[1],\"prefix\":99}".utf8)); fatalError("corrupt route journal accepted") } catch {}
        let split = ProxyNetworkSnapshot(routes: [ProxyRoute(prefix: try ProxyCIDR("172.27.0.0/16"), gateway: "10.8.0.1", interface: "utun2")])
        do { try ProxyTunnelBindingPolicy.validate(split, networks: ["utun2": [try ProxyCIDR("10.8.0.0/24")]]); fatalError("unsafe split route binding accepted") } catch {}
        try ProxyTunnelBindingPolicy.validate(split, networks: ["utun2": [try ProxyCIDR("172.27.0.0/16")]])
        print("TUN route exclusions, IPv6, VPN conflict, rollback, journal recovery and DNS parser passed")
    }
}
