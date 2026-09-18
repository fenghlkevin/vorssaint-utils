// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

enum ProxyTunnelPreflight {
    static func plan(inspection: ProxyInspection, settings: ProxyTunnelSettings) async throws -> ProxyTunnelPlan {
        var exclusions = Set(settings.exclusions)
        for rule in inspection.source["rules"] as? [String] ?? [] {
            let pieces = rule.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count >= 3, ["IP-CIDR", "IP-CIDR6"].contains(pieces[0]), pieces[2] == "DIRECT" { exclusions.insert(try ProxyCIDR(pieces[1]).description) }
        }
        let nodes = inspection.source["proxies"] as? [[String: Any]] ?? []
        var hosts = Set(nodes.compactMap { $0["server"] as? String })
        let dns = inspection.source["dns"] as? [String: Any] ?? [:]
        // Keep DNS servers on the original network path, including company DNS.
        for value in (dns["nameserver"] as? [String] ?? []) + (dns["fallback"] as? [String] ?? []) + (dns["default-nameserver"] as? [String] ?? []) {
            if let host = URL(string: value.contains("://") ? value : "udp://" + value)?.host { hosts.insert(host) }
        }
        if let policies = dns["nameserver-policy"] as? [String: Any] {
            for value in policies.values {
                for server in (value as? [String] ?? (value as? String).map { [$0] } ?? []) {
                    if let host = URL(string: server.contains("://") ? server : "udp://" + server)?.host { hosts.insert(host) }
                }
            }
        }
        for host in hosts.sorted() {
            try Task.checkCancellation()
            let addresses = try await resolve(host)
            guard !addresses.isEmpty else { throw ProxyFailure.message("节点或 DNS 服务器的系统解析失败，增强模式未启用。") }
            for address in addresses { exclusions.insert(try ProxyCIDR(address).description) }
        }
        let plan = ProxyTunnelPlan(ipv6: settings.ipv6, exclusions: exclusions.sorted())
        let snapshot = try await Task.detached { try ProxyNetworkSnapshot.read() }.value
        _ = try plan.routes(snapshot: snapshot)
        try ProxyTunnelBindingPolicy.validate(snapshot, networks: ProxyTunnelBindingPolicy.interfaceNetworks())
        return plan
    }
    static func resolve(_ host: String) async throws -> [String] {
        if let ip = try? ProxyCIDR(host), ip.prefix == (ip.isIPv6 ? 128 : 32) { return [ip.address] }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ProxyReplyGate<[String]>(continuation)
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC
                var first: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &first) == 0 else { gate.fail(ProxyFailure.message("节点或 DNS 服务器系统解析失败。")); return }
                defer { if let first { freeaddrinfo(first) } }
                var current = first, addresses = Set<String>()
                while let item = current {
                    defer { current = item.pointee.ai_next }
                    var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let value = String(cString: text)
                        if !value.contains("%") { addresses.insert(value) }
                    }
                }
                gate.succeed(addresses.sorted())
            }
        }
    }
}
