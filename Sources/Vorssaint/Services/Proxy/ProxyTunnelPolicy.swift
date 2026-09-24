// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct ProxyTunnelSettings: Codable, Equatable {
    var enabled = false
    var ipv6 = false
    var exclusions: [String] = []
}
struct ProxyTunnelRuntime {
    let interface: String
    let address4: String
    let address6: String?
    var preservedRoutes: [ProxyRoute] = []
}

struct ProxyTunnelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ProxyCIDR: Hashable, Codable, CustomStringConvertible {
    let bytes: [UInt8]
    let prefix: Int
    var isIPv6: Bool { bytes.count == 16 }
    init(_ text: String) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let raw = parts.first, !raw.contains("%") else { throw ProxyTunnelError(message: "无效的 IP 网段。") }
        let family = raw.contains(":") ? AF_INET6 : AF_INET
        var data = [UInt8](repeating: 0, count: family == AF_INET6 ? 16 : 4)
        let mask = parts.count == 2 ? Int(parts[1]) : data.count * 8
        guard let mask, (0...data.count * 8).contains(mask), inet_pton(family, String(raw), &data) == 1 else { throw ProxyTunnelError(message: "无效的 IP 网段：\(text.prefix(80))") }
        for bit in mask..<data.count * 8 { data[bit / 8] &= ~(1 << (7 - bit % 8)) }
        bytes = data; prefix = mask
    }
    private enum CodingKeys: String, CodingKey { case bytes, prefix }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let data = try values.decode([UInt8].self, forKey: .bytes)
        let mask = try values.decode(Int.self, forKey: .prefix)
        guard [4, 16].contains(data.count), (0...data.count * 8).contains(mask) else {
            throw ProxyTunnelError(message: "路由恢复记录包含无效网段。")
        }
        var canonical = data
        for bit in mask..<data.count * 8 { canonical[bit / 8] &= ~(1 << (7 - bit % 8)) }
        guard canonical == data else { throw ProxyTunnelError(message: "路由恢复记录包含非规范网段。") }
        bytes = data; prefix = mask
    }
    private init(bytes: [UInt8], prefix: Int) { self.bytes = bytes; self.prefix = prefix }
    var address: String {
        var data = bytes, buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = inet_ntop(isIPv6 ? AF_INET6 : AF_INET, &data, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }
    var description: String { "\(address)/\(prefix)" }
    func contains(_ other: ProxyCIDR) -> Bool {
        guard bytes.count == other.bytes.count, prefix <= other.prefix else { return false }
        for bit in 0..<prefix where (bytes[bit / 8] & (1 << (7 - bit % 8))) != (other.bytes[bit / 8] & (1 << (7 - bit % 8))) { return false }
        return true
    }
    func subtract(_ other: ProxyCIDR) -> [ProxyCIDR] {
        if other.contains(self) { return [] }
        guard contains(other), prefix < bytes.count * 8 else { return [self] }
        var right = bytes; right[prefix / 8] |= 1 << (7 - prefix % 8)
        return ProxyCIDR(bytes: bytes, prefix: prefix + 1).subtract(other) + ProxyCIDR(bytes: right, prefix: prefix + 1).subtract(other)
    }
    static func netstat(_ value: String, ipv6: Bool) -> ProxyCIDR? {
        if value == "default" { return try? .init(ipv6 ? "::/0" : "0.0.0.0/0") }
        let unscoped = value.replacingOccurrences(of: "%[^/]+", with: "", options: .regularExpression)
        if ipv6 { return try? .init(unscoped) }
        let pieces = unscoped.split(separator: "/")
        guard let head = pieces.first else { return nil }
        var octets = head.split(separator: ".").map(String.init)
        guard !octets.isEmpty, octets.count <= 4 else { return nil }
        let implicit = octets.count * 8
        while octets.count < 4 { octets.append("0") }
        return try? .init(octets.joined(separator: ".") + "/" + (pieces.count == 2 ? String(pieces[1]) : String(implicit)))
    }
}
struct ProxyRoute: Hashable, Codable {
    let prefix: ProxyCIDR
    let gateway: String
    let interface: String
    var isTunnel: Bool { interface.hasPrefix("utun") || interface.hasPrefix("tun") || interface.hasPrefix("ppp") || interface.hasPrefix("ipsec") }
}
struct ProxyNetworkSnapshot: Codable, Equatable {
    let routes: [ProxyRoute]
    var fingerprint: [String] {
        routes.filter { $0.prefix.prefix == 0 || $0.isTunnel || $0.prefix.prefix < ($0.prefix.isIPv6 ? 128 : 32) }
            .map { "\($0.prefix)|\($0.gateway)|\($0.interface)" }.sorted()
    }
    static func parse(_ text: String, ipv6: Bool, excluding: String? = nil) -> [ProxyRoute] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 4, let prefix = ProxyCIDR.netstat(parts[0], ipv6: ipv6),
                  parts[2].contains("U"), !parts[2].contains("L"), !parts[2].contains("W") else { return nil }
            // macOS netstat -rn: Destination Gateway Flags Netif [Expire].
            let interface = parts[3]
            guard interface != excluding, interface != "lo0", interface.range(of: "^[a-zA-Z][a-zA-Z0-9]*$", options: .regularExpression) != nil else { return nil }
            return ProxyRoute(prefix: prefix, gateway: parts[1], interface: interface)
        }
    }
    static func read(excluding: String? = nil) throws -> ProxyNetworkSnapshot {
        let v4 = try ProxyNetworkCommand.run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let v6 = try ProxyNetworkCommand.run("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
        return .init(routes: parse(v4, ipv6: false, excluding: excluding) + parse(v6, ipv6: true, excluding: excluding))
    }
}
struct ProxyTunnelPlan: Codable {
    var ipv6 = false
    var exclusions: [String] = []
    static let localExclusions = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/3", "::/128", "::1/128", "::ffff:0:0/96", "fc00::/7", "fe80::/10", "ff00::/8"]
    func routes(snapshot: ProxyNetworkSnapshot) throws -> [ProxyCIDR] {
        guard exclusions.count <= 256 else { throw ProxyTunnelError(message: "TUN 排除项超过 256 条。") }
        guard snapshot.routes.contains(where: { !$0.isTunnel && !$0.prefix.isIPv6 && $0.prefix.prefix == 0 }) else { throw ProxyTunnelError(message: "缺少物理 IPv4 默认路由，暂不启用 TUN。") }
        if snapshot.routes.contains(where: { $0.isTunnel && $0.prefix.prefix <= 1 && (ipv6 || !$0.prefix.isIPv6) }) {
            throw ProxyTunnelError(message: "检测到 VPN 全隧道默认路由；为避免争夺出口，增强模式已暂停。可继续使用系统代理。")
        }
        var excluded = try (Self.localExclusions + exclusions).map(ProxyCIDR.init)
        // Preserve all pre-existing non-default routes, especially VPN/company paths.
        excluded += snapshot.routes.filter { $0.prefix.prefix > 0 }.map(\.prefix)
        var result = try [ProxyCIDR("0.0.0.0/0")]
        if ipv6 {
            guard snapshot.routes.contains(where: { !$0.isTunnel && $0.prefix.isIPv6 && $0.prefix.prefix == 0 }) else { throw ProxyTunnelError(message: "未检测到物理 IPv6 默认路由，请关闭 IPv6 接管或恢复 IPv6 网络。") }
            result.append(try ProxyCIDR("::/0"))
        }
        for exclusion in excluded {
            result = result.flatMap { $0.subtract(exclusion) }
            guard result.count <= 512 else { throw ProxyTunnelError(message: "排除网络过于复杂，路由计划超过 512 条；增强模式未启用。") }
        }
        guard !result.isEmpty else { throw ProxyTunnelError(message: "没有可接管的公网路由。") }
        return result
    }
}

enum ProxyNetworkCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); watchdog.cancel()
        guard process.terminationStatus == 0, data.count <= 4 * 1024 * 1024 else { throw ProxyTunnelError(message: "网络命令执行失败（\(URL(fileURLWithPath: executable).lastPathComponent)）。") }
        return String(decoding: data, as: UTF8.self)
    }
}
