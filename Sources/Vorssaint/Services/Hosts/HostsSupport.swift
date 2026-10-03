// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct HostsFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct HostsProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var content: String
    var enabled = false
}
struct HostsBackup: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var managedContent: String
    var systemContent: String
}
struct HostsWriteRequest: Codable {
    var expected: String
    var managedContent: String
}
struct HostsWriteReply: Codable {
    var success = false
    var message = ""
    var content: String?
}
struct HostsIssue: Identifiable {
    let id = UUID()
    let message: String
    let blocking: Bool
}

enum HostsSupport {
    static let limit = 1_048_576
    static let begin = "# BEGIN VORSSAINT HOSTS"
    static let end = "# END VORSSAINT HOSTS"

    /// Include the separator added by compose, so removing our block restores
    /// even an original file without a trailing newline byte for byte.
    static func split(_ text: String) throws -> (base: String, managed: String) {
        guard text.utf8.count <= limit, !text.contains("\0") else { throw HostsFailure(message: "Hosts 文件过大或含有空字符。") }
        let starts = text.components(separatedBy: begin).count - 1
        let ends = text.components(separatedBy: end).count - 1
        if starts == 0 && ends == 0 { return (text, "") }
        guard starts == 1, ends == 1,
              let first = text.range(of: "\n" + begin + "\n"),
              let last = text.range(of: end + "\n", range: first.upperBound..<text.endIndex),
              last.lowerBound == first.upperBound || text[text.index(before: last.lowerBound)] == "\n"
        else { throw HostsFailure(message: "Vorssaint 管理区块标记损坏或重复，请检查系统 Hosts 后重试。") }
        return (String(text[..<first.lowerBound]) + String(text[last.upperBound...]),
                String(text[first.upperBound..<last.lowerBound]))
    }
    static func compose(current: String, managed: String) throws -> String {
        let base = try split(current).base
        guard !managed.contains(begin), !managed.contains(end) else { throw HostsFailure(message: "配置不能包含系统管理标记。") }
        guard !issues(managed).contains(where: \.blocking) else { throw HostsFailure(message: "请先修复 Hosts 语法错误或域名冲突。") }
        let result = managed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? base : base + "\n" + begin + "\n" + managed + (managed.hasSuffix("\n") ? "" : "\n") + end + "\n"
        guard result.utf8.count <= limit else { throw HostsFailure(message: "合并后的 Hosts 文件超过 1 MB。") }
        return result
    }
    static func aggregate(_ profiles: [HostsProfile]) -> String {
        let content = profiles.filter(\.enabled).map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        return content.isEmpty ? "" : content + "\n"
    }

    static func validIP(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    static func validDomain(_ value: String) -> Bool {
        let name = value.hasSuffix(".") ? String(value.dropLast()) : value
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
        }
    }
    static func records(_ text: String) -> [(line: Int, ip: String, domains: [String])] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let tokens = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !tokens.isEmpty else { return nil }
            return (index + 1, tokens[0], Array(tokens.dropFirst()))
        }
    }
    static func issues(_ text: String, base: String = "") -> [HostsIssue] {
        var result: [HostsIssue] = []
        if text.utf8.count > limit || text.contains("\0") || text.contains(begin) || text.contains(end) {
            result.append(.init(message: "配置过大，含空字符或保留的管理标记。", blocking: true))
        }
        var seen: [String: Set<String>] = [:]
        for record in records(text) {
            if !validIP(record.ip) || record.domains.isEmpty || !record.domains.allSatisfy(validDomain) {
                result.append(.init(message: "第 \(record.line) 行：需要有效的 IPv4 / IPv6 和域名（国际域名请使用 Punycode）。", blocking: true)); continue
            }
            for domain in record.domains {
                let key = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                seen[key, default: []].insert(record.ip)
            }
        }
        // IPv4 and IPv6 may coexist for one hostname; conflicting addresses
        // within the same address family are ambiguous and block application.
        for (domain, ips) in seen.sorted(by: { $0.key < $1.key }) {
            if ips.filter({ !$0.contains(":") }).count > 1 || ips.filter({ $0.contains(":") }).count > 1 {
                result.append(.init(message: "域名冲突：\(domain) → \(ips.sorted().joined(separator: ", "))", blocking: true))
            }
        }
        for record in records(base) where validIP(record.ip) {
            for domain in record.domains {
                let key = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if let ips = seen[key], ips.contains(where: { $0.contains(":") == record.ip.contains(":") && $0 != record.ip }) {
                    result.append(.init(message: "系统原有记录冲突：\(domain) → \(record.ip)。请先在系统 Hosts 中处理。", blocking: true))
                }
            }
        }
        return result
    }
}
