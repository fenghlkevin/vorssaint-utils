// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NetworkFlowCounter: Equatable {
    let downloaded: Double
    let uploaded: Double
    var downloadRate: Double?
    var uploadRate: Double?
    var total: Double { downloaded + uploaded }
}

enum NetworkFlowSupport {
    /// tcp6 endpoints use address.port in nettop and [address]:port in lsof.
    static func endpoint(_ raw: String, ipv6: Bool) -> String? {
        guard !raw.contains("*"), !raw.isEmpty else { return nil }
        if ipv6 {
            guard let dot = raw.lastIndex(of: "."), Int(raw[raw.index(after: dot)...]) != nil else { return nil }
            return "[\(raw[..<dot])]:\(raw[raw.index(after: dot)...])"
        }
        guard let colon = raw.lastIndex(of: ":"), Int(raw[raw.index(after: colon)...]) != nil else { return nil }
        return raw
    }
    static func key(pid: Int32, local: String, remote: String) -> String { "\(pid)|\(local)|\(remote)" }
    static func matchesSource(local: String, remote: String, sourceIP: String, sourcePort: String, proxyPort: Int) -> Bool {
        guard (1...65535).contains(proxyPort), let port = Int(sourcePort), (1...65535).contains(port),
              !sourceIP.isEmpty, remote == "127.0.0.1:\(proxyPort)" || remote == "[::1]:\(proxyPort)" else { return false }
        let source = sourceIP.contains(":") ? "[\(sourceIP)]:\(port)" : "\(sourceIP):\(port)"
        return local == source
    }
    static func parse(_ text: String) -> [String: NetworkFlowCounter] {
        var pid: Int32?
        var result: [String: NetworkFlowCounter] = [:]
        for line in text.split(separator: "\n") {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.count >= 4 else { continue }
            if cells[0] == "time" { result.removeAll(); pid = nil; continue }
            let label = cells[1]
            if label.hasPrefix("tcp4 ") || label.hasPrefix("tcp6 ") {
                guard let pid else { continue }
                let endpoints = String(label.dropFirst(5)).components(separatedBy: "<->")
                guard endpoints.count == 2,
                      let local = endpoint(endpoints[0], ipv6: label.hasPrefix("tcp6")),
                      let remote = endpoint(endpoints[1], ipv6: label.hasPrefix("tcp6")),
                      let down = Double(cells[2]), let up = Double(cells[3]),
                      down.isFinite, up.isFinite, down >= 0, up >= 0 else { continue }
                let id = key(pid: pid, local: local, remote: remote)
                result[id] = .init(downloaded: down, uploaded: up)
            } else if !label.hasPrefix("udp"), let dot = label.lastIndex(of: ".") {
                // Never let an unparseable process row inherit the preceding pid.
                pid = Int32(label[label.index(after: dot)...])
            } else if !label.hasPrefix("udp") { pid = nil }
        }
        return result
    }
}

struct NetworkFlowRateTracker {
    private var previous: [String: NetworkFlowCounter] = [:]
    private var time: TimeInterval?
    mutating func reset() { previous = [:]; time = nil }
    mutating func sample(_ values: [String: NetworkFlowCounter], now: TimeInterval) -> [String: NetworkFlowCounter] {
        let elapsed = time.map { now - $0 } ?? 0
        let valid = elapsed > 0 && elapsed < 20
        defer { previous = values; time = now }
        return values.reduce(into: [:]) { result, pair in
            var value = pair.value
            if valid, let old = previous[pair.key], value.downloaded >= old.downloaded, value.uploaded >= old.uploaded {
                value.downloadRate = (value.downloaded - old.downloaded) / elapsed
                value.uploadRate = (value.uploaded - old.uploaded) / elapsed
            }
            result[pair.key] = value
        }
    }
}
