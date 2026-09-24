// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ProxyTunnelIdentity: Codable, Equatable {
    let name: String
    let index: UInt32
    let ipv4: String
    let ipv6: String?
}
protocol ProxyTunnelNetwork: AnyObject {
    func snapshot(excluding: String?) throws -> ProxyNetworkSnapshot
    func create(ipv6: Bool) throws -> (ProxyTunnelIdentity, Int32)
    func owns(_ identity: ProxyTunnelIdentity) -> Bool
    func add(_ route: ProxyCIDR, to identity: ProxyTunnelIdentity) throws
    func remove(_ route: ProxyCIDR, from identity: ProxyTunnelIdentity) throws
    func addRoutes(_ routes: [ProxyCIDR], to identity: ProxyTunnelIdentity) throws
    func removeRoutes(_ routes: [ProxyCIDR], from identity: ProxyTunnelIdentity) throws
    func close(_ descriptor: Int32, identity: ProxyTunnelIdentity)
}
extension ProxyTunnelNetwork {
    func addRoutes(_ routes: [ProxyCIDR], to identity: ProxyTunnelIdentity) throws { for route in routes { try add(route, to: identity) } }
    func removeRoutes(_ routes: [ProxyCIDR], from identity: ProxyTunnelIdentity) throws { for route in routes { try remove(route, from: identity) } }
}
struct ProxyTunnelJournal: Codable {
    let identity: ProxyTunnelIdentity
    var routes: [ProxyCIDR]
}
final class ProxyTunnelLease {
    private let backend: ProxyTunnelNetwork
    private let journalURL: URL
    private(set) var identity: ProxyTunnelIdentity?
    private(set) var descriptor: Int32 = -1
    private(set) var active = false
    private var planned: [ProxyCIDR] = []
    private var baseline: ProxyNetworkSnapshot?
    init(backend: ProxyTunnelNetwork, journal: URL) { self.backend = backend; journalURL = journal }
    func prepare(_ plan: ProxyTunnelPlan) throws {
        guard identity == nil else { throw ProxyTunnelError(message: "已有增强模式会话，请先停止。") }
        try recover()
        let snapshot = try backend.snapshot(excluding: nil)
        let routes = try plan.routes(snapshot: snapshot)
        let (identity, fd) = try backend.create(ipv6: plan.ipv6)
        self.identity = identity; descriptor = fd; baseline = snapshot; planned = routes
        do { try save(.init(identity: identity, routes: [])) }
        catch { backend.close(fd, identity: identity); self.identity = nil; descriptor = -1; throw error }
    }
    func activate() throws {
        guard let identity, let baseline, backend.owns(identity) else { throw ProxyTunnelError(message: "TUN 网卡会话已失效。") }
        guard try backend.snapshot(excluding: identity.name).fingerprint == baseline.fingerprint else { throw ProxyTunnelError(message: "校验期间网络发生变化，请重新开启增强模式。") }
        // Write ahead of every possible route mutation; cleanup checks exact ownership.
        try save(.init(identity: identity, routes: planned))
        do {
            try backend.addRoutes(planned, to: identity)
            let actual = try backend.snapshot(excluding: nil).routes
            guard planned.allSatisfy({ route in actual.contains { $0.prefix == route && $0.interface == identity.name } }) else { throw ProxyTunnelError(message: "TUN 路由写入后回读不一致。") }
            guard try backend.snapshot(excluding: identity.name).fingerprint == baseline.fingerprint else { throw ProxyTunnelError(message: "添加路由期间网络发生变化，已撤销增强模式。") }
            active = true
        } catch { try restore(); throw error }
    }
    func checkNetwork() throws {
        guard active, let identity, let baseline else { return }
        let current = try backend.snapshot(excluding: identity.name)
        if !backend.owns(identity) || current.fingerprint != baseline.fingerprint {
            try restore()
            throw ProxyTunnelError(message: "默认出口或 VPN 路由发生变化，已暂停增强模式；请检查后重新开启。")
        }
    }
    func restore() throws {
        try recover()
        if let identity { backend.close(descriptor, identity: identity) }
        identity = nil; descriptor = -1; baseline = nil; planned = []; active = false
    }
    func recover() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let record = try JSONDecoder().decode(ProxyTunnelJournal.self, from: Data(contentsOf: journalURL))
        if backend.owns(record.identity) {
            try backend.removeRoutes(Array(record.routes.reversed()), from: record.identity)
        }
        // An absent/reused interface is never touched; all deletions are identity checked.
        try FileManager.default.removeItem(at: journalURL)
    }
    private func save(_ value: ProxyTunnelJournal) throws {
        try JSONEncoder().encode(value).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
    var routeCount: Int { active ? planned.count : 0 }
}
