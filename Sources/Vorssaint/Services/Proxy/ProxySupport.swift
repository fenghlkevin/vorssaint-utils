// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import ProxyYAML
import CryptoKit

enum ProxyFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
struct ProxyIssue: Identifiable, Equatable {
    enum Severity { case warning, repair, error }
    let id = UUID()
    let severity: Severity
    let message: String
}
struct ProxyPreferences: Codable, Equatable {
    var mixedPort = 7890
    var controllerPort = 19090
    var allowLAN = false
    var systemProxy = true
    var autoStart = false
    var mode = "rule"
    var repairReferences = false
    var dnsPort = 1053
    var selections: [String: String] = [:]
    var tunnel: ProxyTunnelSettings? = nil
    var tunnelSettings: ProxyTunnelSettings { get { tunnel ?? .init() } set { tunnel = newValue } }
    func validate() throws {
        guard tunnelSettings.exclusions.count <= 256 else { throw ProxyFailure.message("排除项不能超过 256 条。") }
        for value in tunnelSettings.exclusions { _ = try ProxyCIDR(value) }
        let ports = [mixedPort, controllerPort, dnsPort]
        guard ports.allSatisfy({ (1024...65535).contains($0) }), Set(ports).count == ports.count else {
            throw ProxyFailure.message("代理、控制和 DNS 端口必须互不相同，并在 1024–65535 之间。")
        }
        guard ["rule", "global", "direct"].contains(mode) else { throw ProxyFailure.message("不支持的出站模式。") }
    }
}
struct ProxyProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let importedAt: Date
}
struct ProxyGroup: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var members: [String]
    var selected: String
}
struct ProxyInspection {
    let source: [String: Any]
    let issues: [ProxyIssue]
    let nodeNames: [String]
    let groups: [ProxyGroup]
    let ruleCount: Int
    let requiredProviders: [String]
    var hasErrors: Bool { issues.contains { $0.severity == .error } }
}
enum ProxyConfigCompiler {
    static func document(_ data: Data) throws -> [String: Any] {
        var parseError: NSError?
        guard let json = VPYAMLToJSON(data, &parseError) else { throw parseError ?? NSError(domain: "ProxyYAML", code: 1) }
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw ProxyFailure.message("配置根节点必须是映射。") }
        return root
    }
    static func providerPath(_ name: String, _ provider: [String: Any]) -> String {
        let identity = [name, provider["url"] as? String ?? "", provider["behavior"] as? String ?? "", provider["format"] as? String ?? "yaml"].joined(separator: "\n")
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "ruleset/\(hash).yaml"
    }
    static func inspect(_ data: Data) throws -> ProxyInspection {
        let root = try document(data)
        var issues: [ProxyIssue] = []
        func issue(_ level: ProxyIssue.Severity, _ text: String) { issues.append(.init(severity: level, message: text)) }
        let supported: Set<String> = ["mixed-port", "external-controller", "secret", "allow-lan", "bind-address", "mode", "log-level", "ipv6", "dns", "proxies", "proxy-groups", "rule-providers", "rules", "hosts", "profile", "find-process-mode", "unified-delay", "tcp-concurrent"]
        for key in root.keys.sorted() where !supported.contains(key) { issue(.error, "本阶段不支持配置字段：\(key)。请移除后导入；不会静默忽略。") }
        let nodes = root["proxies"] as? [[String: Any]] ?? []
        if root["proxies"] != nil && !(root["proxies"] is [[String: Any]]) { issue(.error, "proxies 必须是节点列表。") }
        var names: [String] = []
        for (index, node) in nodes.enumerated() {
            guard let name = node["name"] as? String, !name.isEmpty, let type = node["type"] as? String else { issue(.error, "节点 \(index + 1) 缺少名称或类型。"); continue }
            names.append(name)
            if !["ss", "vless"].contains(type) { issue(.error, "节点 \(index + 1)：第一阶段只支持 SS 和 VLESS。") }
            if node["server"] as? String == nil || node["port"] as? Int == nil { issue(.error, "节点 \(index + 1) 缺少服务器或数值端口。") }
        }
        let rawGroups = root["proxy-groups"] as? [[String: Any]] ?? []
        var groups: [ProxyGroup] = []
        for (index, group) in rawGroups.enumerated() {
            guard let name = group["name"] as? String, !name.isEmpty,
                  group["type"] as? String == "select", let members = group["proxies"] as? [String], !members.isEmpty else {
                issue(.error, "策略组 \(index + 1) 必须是包含成员的 select 组。"); continue
            }
            groups.append(.init(name: name, members: members, selected: members[0]))
        }
        let allNames = names + groups.map(\.name)
        if Set(allNames).count != allNames.count { issue(.error, "节点与策略组名称不能重复。") }
        let builtin: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"]
        if allNames.contains(where: { builtin.contains($0) }) { issue(.error, "节点或策略组使用了保留名称。") }
        let known = Set(allNames).union(builtin)
        for group in groups {
            for member in group.members where !known.contains(member) { issue(.error, "策略组 \(group.name) 引用了不存在的成员。") }
        }
        let map = Dictionary(groups.map { ($0.name, $0.members) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<String>()
        func cycle(_ name: String, _ path: Set<String>) -> Bool {
            guard let children = map[name] else { return false }
            if path.contains(name) || path.count >= 64 { return true }
            if visited.contains(name) { return false }
            if children.contains(where: { cycle($0, path.union([name])) }) { return true }
            visited.insert(name); return false
        }
        if groups.contains(where: { cycle($0.name, []) }) { issue(.error, "策略组存在循环引用或嵌套超过 64 层。") }
        if root["proxy-groups"] != nil && !(root["proxy-groups"] is [[String: Any]]) { issue(.error, "proxy-groups 必须是列表。") }
        if root["rule-providers"] != nil && !(root["rule-providers"] is [String: [String: Any]]) { issue(.error, "rule-providers 必须是映射。") }
        guard let rules = root["rules"] as? [String] else { throw ProxyFailure.message("配置缺少 rules 字符串列表。") }
        let providers = root["rule-providers"] as? [String: [String: Any]] ?? [:]
        for (name, provider) in providers {
            guard provider["type"] as? String == "http", let text = provider["url"] as? String,
                  let url = URL(string: text), ["https", "http"].contains(url.scheme ?? ""), url.host != nil,
                  ["domain", "ipcidr", "classical"].contains(provider["behavior"] as? String ?? "") else {
                issue(.error, "规则集 \(name) 必须是有效的 HTTP 规则集。"); continue
            }
        }
        var required = Set<String>(), repairs = 0, afterMatch = false
        let ruleTypes: Set<String> = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "PROCESS-NAME", "RULE-SET", "GEOIP", "MATCH"]
        for (index, rule) in rules.enumerated() {
            let parts = rule.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = parts.first, ruleTypes.contains(type), parts.count >= (type == "MATCH" ? 2 : 3) else {
                issue(.error, "规则 \(index + 1) 的类型或参数不受支持。"); continue
            }
            if afterMatch { issue(.warning, "规则 \(index + 1) 位于 MATCH 后，不会生效；保留原顺序。") }
            if type == "MATCH" { afterMatch = true }
            if type == "RULE-SET" {
                required.insert(parts[1])
                if providers[parts[1]] == nil { issue(.error, "规则 \(index + 1) 引用了不存在的规则集。") }
            }
            let target = parts[type == "MATCH" ? 1 : 2]
            if !known.contains(target) {
                let matches = allNames.filter { $0.lowercased() == target.lowercased() }
                if matches.count == 1 { repairs += 1 }
                else { issue(.error, "规则 \(index + 1) 的策略目标不存在或存在歧义。") }
            }
            if type == "IP-CIDR", parts[1] == "152.136.138.142/24" { issue(.warning, "规则 \(index + 1) 的 /24 包含主机位，请确认网段范围。") }
        }
        if repairs > 0 { issue(.repair, "\(repairs) 处策略引用仅大小写不同；勾选“修复引用”后按唯一名称转换。") }
        if let dns = root["dns"] as? [String: Any], let listen = dns["listen"] as? String {
            issue(.warning, "DNS 监听 \(listen) 将覆盖为本机 127.0.0.1 的高位端口。")
        }
        if (root["dns"] as? [String: Any])?["proxy-server-nameserver"] == nil { issue(.warning, "节点服务器域名使用系统 DNS 进行引导解析；公司域名 policy 与业务 DNS 配置保持不变。") }
        issue(.warning, "运行时固定本地 Controller、随机访问密钥与私有缓存路径；原始配置不变。")
        return ProxyInspection(source: root, issues: issues, nodeNames: names, groups: groups, ruleCount: rules.count, requiredProviders: required.sorted())
    }
    static func compile(_ inspection: ProxyInspection, preferences: ProxyPreferences, secret: String, tunnel: ProxyTunnelRuntime? = nil) throws -> Data {
        try preferences.validate()
        guard !inspection.hasErrors else { throw ProxyFailure.message("配置有阻断项，请先修复后重新导入。") }
        if inspection.issues.contains(where: { $0.severity == .repair }) && !preferences.repairReferences {
            throw ProxyFailure.message("请确认策略名称兼容修复后再启动。")
        }
        var root = inspection.source
        root["mixed-port"] = preferences.mixedPort
        root["allow-lan"] = preferences.allowLAN
        root["bind-address"] = preferences.allowLAN ? "*" : "127.0.0.1"
        root["external-controller"] = "127.0.0.1:\(preferences.controllerPort)"
        root["secret"] = secret
        root["mode"] = preferences.mode
        // Resolve local client names even when the matching rule does not inspect processes.
        root["find-process-mode"] = "always"
        root["tun"] = ["enable": false]
        if let tunnel {
            var tun: [String: Any] = ["enable": true, "device": tunnel.interface, "file-descriptor": 3, "stack": "gvisor", "auto-route": false, "auto-detect-interface": true, "dns-hijack": [String](), "mtu": 1500, "inet4-address": [tunnel.address4 + "/30"]]
            if let address6 = tunnel.address6 { tun["inet6-address"] = [address6 + "/126"]; root["ipv6"] = true }
            else { tun["inet6-address"] = [String]() }
            root["tun"] = tun
        }
        root["profile"] = ["store-selected": false]
        var dns = root["dns"] as? [String: Any] ?? [:]
        dns["listen"] = "127.0.0.1:\(preferences.dnsPort)"
        if dns["proxy-server-nameserver"] == nil { dns["proxy-server-nameserver"] = ["system"] }
        root["dns"] = dns
        let names = inspection.nodeNames + inspection.groups.map(\.name)
        if preferences.repairReferences, let rules = root["rules"] as? [String] {
            root["rules"] = rules.map { rule in
                var parts = rule.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let i = parts.first == "MATCH" ? 1 : 2
                if parts.count > i, !["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"].contains(parts[i]), !names.contains(parts[i]), let name = names.first(where: { $0.lowercased() == parts[i].lowercased() }) { parts[i] = name }
                return parts.joined(separator: ",")
            }
        }
        if var providers = root["rule-providers"] as? [String: [String: Any]] {
            for name in providers.keys.sorted() { let path = providerPath(name, providers[name]!); providers[name]?["path"] = "./" + path }
            root["rule-providers"] = providers
        }
        // JSON is a YAML subset, avoiding a second lossy emitter. The original text remains untouched.
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    static func shellCommands(host: String = "127.0.0.1", port: Int) -> String {
        let address = host.contains(":") ? "[\(host)]" : host
        return "export http_proxy='http://\(address):\(port)'\nexport https_proxy='http://\(address):\(port)'\nexport all_proxy='socks5h://\(address):\(port)'"
    }
}
