// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import Security
import SystemConfiguration

protocol ProxyNetworkStore: AnyObject {
    func activeService() throws -> String?
    func read(_ service: String) throws -> [String: Any]
    func write(_ service: String, _ values: [String: Any], expected: [String: Any]) throws
}
struct ProxyNetworkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
/// A field-level write-ahead journal; foreign changes are never overwritten on restoration.
final class ProxySystemLease {
    let store: ProxyNetworkStore
    let journal: URL
    private(set) var records: [String: [String: Any]] = [:]
    private(set) var ownedService: String?
    init(store: ProxyNetworkStore, journal: URL) throws {
        self.store = store; self.journal = journal
        if FileManager.default.fileExists(atPath: journal.path) {
            let data = try Data(contentsOf: journal)
            guard let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
                throw ProxyNetworkError(message: "系统代理恢复记录损坏，请保留该文件并检查系统代理设置。")
            }
            records = decoded
        }
    }
    static func desired(port: Int) -> [String: Any] {
        ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
         "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port,
         "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
    }
    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?): return NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
        default: return false
        }
    }
    private func save() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: records, format: .binary, options: 0)
        try data.write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    func restore() throws {
        for service in records.keys.sorted() {
            guard let entry = records[service], let original = entry["original"] as? [String: Any],
                  let written = entry["written"] as? [String: Any] else {
                throw ProxyNetworkError(message: "系统代理恢复记录格式无效。")
            }
            let snapshot = try store.read(service)
            var current = snapshot
            var changed = false
            let families = [["HTTPEnable", "HTTPProxy", "HTTPPort"], ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"], ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"], ["ProxyAutoConfigEnable"], ["ProxyAutoDiscoveryEnable"]]
            for family in families where family.allSatisfy({ Self.equal(current[$0], written[$0]) }) {
                for key in family {
                    if !Self.equal(current[key], original[key]) { changed = true }
                    current[key] = original[key]
                }
            }
            if changed { try store.write(service, current, expected: snapshot) }
            records.removeValue(forKey: service)
            try save()
        }
        ownedService = nil
    }
    func enable(port: Int) throws {
        guard let service = try store.activeService() else { throw ProxyNetworkError(message: "没有可用的物理网络服务，系统代理未开启。") }
        if ownedService == service {
            let current = try store.read(service)
            guard Self.desired(port: port).allSatisfy({ Self.equal(current[$0.key], $0.value) }) else {
                throw ProxyNetworkError(message: "系统代理已被其他程序修改，已停止接管。")
            }
            return
        }
        try restore()
        let original = try store.read(service)
        let desired = Self.desired(port: port)
        records[service] = ["original": original, "written": desired]
        try save() // Must succeed before touching the OS.
        var updated = original
        desired.forEach { updated[$0.key] = $0.value }
        do {
            try store.write(service, updated, expected: original)
            let actual = try store.read(service)
            guard desired.allSatisfy({ Self.equal(actual[$0.key], $0.value) }) else { throw ProxyNetworkError(message: "系统代理写入后验证失败。") }
            ownedService = service
        } catch {
            try? restore()
            throw error
        }
    }
}

final class SCProxyNetworkStore: ProxyNetworkStore {
    private var authorization: AuthorizationRef?
    deinit { if let authorization { AuthorizationFree(authorization, []) } }
    private func preferences(writing: Bool) throws -> SCPreferences {
        if writing, geteuid() != 0, authorization == nil {
            var ref: AuthorizationRef?
            let status = AuthorizationCreate(nil, nil, [.interactionAllowed, .extendRights, .preAuthorize], &ref)
            guard status == errAuthorizationSuccess, let ref else { throw ProxyNetworkError(message: "系统代理授权未完成（\(status)）。") }
            authorization = ref
        }
        let prefs: SCPreferences?
        if writing, let authorization { prefs = SCPreferencesCreateWithAuthorization(nil, "Vorssaint Proxy" as CFString, nil, authorization) }
        else { prefs = SCPreferencesCreate(nil, "Vorssaint Proxy" as CFString, nil) }
        guard let prefs else { throw ProxyNetworkError(message: "无法读取网络设置。") }
        return prefs
    }
    func activeService() throws -> String? {
        let prefs = try preferences(writing: false)
        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService],
              let dynamic = SCDynamicStoreCreate(nil, "Vorssaint Proxy" as CFString, nil, nil) else { return nil }
        let global = SCDynamicStoreCopyValue(dynamic, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = global?["PrimaryService"] as? String
        let candidates = services.filter { service in
            guard SCNetworkServiceGetEnabled(service), let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) else { return false }
            guard type == kSCNetworkInterfaceTypeEthernet || type == kSCNetworkInterfaceTypeIEEE80211 else { return false }
            guard let rawID = SCNetworkServiceGetServiceID(service) else { return false }
            let id = rawID as String
            let state = SCDynamicStoreCopyValue(dynamic, "State:/Network/Service/\(id)/IPv4" as CFString) as? [String: Any]
            return !(state?["Addresses"] as? [String] ?? []).isEmpty
        }.compactMap { SCNetworkServiceGetServiceID($0) as String? }.sorted()
        return primary.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
    }
    func read(_ service: String) throws -> [String: Any] {
        let prefs = try preferences(writing: false)
        return SCPreferencesPathGetValue(prefs, "/NetworkServices/\(service)/Proxies" as CFString) as? [String: Any] ?? [:]
    }
    func write(_ service: String, _ values: [String: Any], expected: [String: Any]) throws {
        let prefs = try preferences(writing: true)
        guard SCPreferencesLock(prefs, true) else { throw ProxyNetworkError(message: "无法锁定系统网络设置（\(SCError())）。") }
        defer { SCPreferencesUnlock(prefs) }
        // Refuse to recreate a network service that disappeared during a transition.
        guard SCNetworkServiceCopy(prefs, service as CFString) != nil else { return }
        let latest = SCPreferencesPathGetValue(prefs, "/NetworkServices/\(service)/Proxies" as CFString) as? [String: Any] ?? [:]
        guard NSDictionary(dictionary: latest).isEqual(to: expected) else {
            throw ProxyNetworkError(message: "网络设置同时被其他程序修改，请重试。")
        }
        guard SCPreferencesPathSetValue(prefs, "/NetworkServices/\(service)/Proxies" as CFString, values as CFDictionary),
              SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw ProxyNetworkError(message: "系统代理设置失败或授权被取消（\(SCError())）。")
        }
    }
}

/// Single authenticated XPC owner. All calls must run on the helper's serial queue.
/// The lease restores on disconnect, heartbeat expiry, or helper restart.
final class ProxySystemSession {
    let lease: ProxySystemLease
    private(set) var owner: UUID?
    private var port = 0
    private var lastPulse: TimeInterval = 0
    private var stopping = false
    private(set) var issue = ""
    var active: Bool { owner != nil && lease.ownedService != nil }
    init(lease: ProxySystemLease) throws { self.lease = lease; try lease.restore() }
    func set(_ enabled: Bool, port: Int, owner id: UUID, now: TimeInterval) throws {
        guard owner == nil || owner == id else { throw ProxyNetworkError(message: "系统代理由另一个会话管理。") }
        if !enabled { try stop(id); return }
        guard (1024...65535).contains(port) else { throw ProxyNetworkError(message: "代理端口无效。") }
        if owner != nil && self.port != port { try lease.restore() }
        // Keep the owner even on a partial write failure so expiry/disconnect can retry restoration.
        owner = id; self.port = port; lastPulse = now; stopping = false
        do { try lease.enable(port: port); issue = "" }
        catch { issue = error.localizedDescription; try? stop(id); throw error }
    }
    func heartbeat(_ id: UUID, now: TimeInterval) throws {
        guard owner == nil || owner == id else { throw ProxyNetworkError(message: "系统代理会话不匹配。") }
        if owner == id { lastPulse = now }
    }
    func stop(_ id: UUID) throws {
        guard owner == id else { return }
        stopping = true
        try lease.restore(); owner = nil; port = 0; issue = ""; stopping = false
    }
    func tick(now: TimeInterval) {
        guard let owner else { return }
        do {
            if stopping || now - lastPulse > 15 { try stop(owner); issue = "应用心跳中断，系统代理已恢复。" }
            else {
                do { try lease.enable(port: port) }
                catch { let reason = error.localizedDescription; try stop(owner); issue = reason }
            }
        } catch { issue = error.localizedDescription }
    }
}
