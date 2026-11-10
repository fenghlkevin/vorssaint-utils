// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NetworkChainSocket: Identifiable, Equatable {
    let pid: Int32
    let process: String
    let local: String
    let remote: String
    let state: String
    var id: String { "\(pid)|\(local)|\(remote)" }
    var isLoopback: Bool { remote.hasPrefix("127.") || remote.hasPrefix("[::1]:") }
}

enum NetworkChainSupport {
    /// lsof field mode; no whitespace splitting of names or IPv6 addresses.
    static func parse(_ text: String) -> [NetworkChainSocket] {
        var pid: Int32 = 0, name = "", address = "", state = "", tcp = false
        var rows: [NetworkChainSocket] = []
        func append() {
            guard pid > 0, tcp, !address.isEmpty else { return }
            let parts = address.components(separatedBy: "->")
            if parts.count == 2 || state == "LISTEN" {
                rows.append(.init(pid: pid, process: name, local: parts[0], remote: parts.count == 2 ? parts[1] : "", state: state))
            }
        }
        for line in text.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": append(); address = ""; state = ""; tcp = false; pid = Int32(value) ?? 0
            case "c": name = value
            case "f": append(); address = ""; state = ""; tcp = false
            case "P": tcp = value == "TCP"
            case "n": address = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        append()
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }
    static func peer(of row: NetworkChainSocket, in rows: [NetworkChainSocket]) -> NetworkChainSocket? {
        rows.first { $0.local == row.remote && $0.remote == row.local && $0.state == "ESTABLISHED" }
    }
    static func incoming(_ row: NetworkChainSocket, in rows: [NetworkChainSocket]) -> Bool {
        let port = row.local.split(separator: ":").last
        return rows.contains {
            $0.pid == row.pid && $0.state == "LISTEN" && $0.local.split(separator: ":").last == port
                && ($0.local == row.local || $0.local.hasPrefix("*:") || $0.local.hasPrefix("0.0.0.0:") || $0.local.hasPrefix("[::]:"))
        }
    }
    static func appPath(fromProcessPath path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
