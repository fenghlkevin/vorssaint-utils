// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum CommandBarDeveloperTool: String, CaseIterable, Identifiable {
    case json, jsonMinify, base64Encode, base64Decode, urlEncode, urlDecode, timestamp, uuid, diff

    var id: String { rawValue }
    var command: String {
        switch self {
        case .json: return "json"
        case .jsonMinify: return "json min"
        case .base64Encode: return "base64 encode"
        case .base64Decode: return "base64 decode"
        case .urlEncode: return "url encode"
        case .urlDecode: return "url decode"
        case .timestamp: return "timestamp"
        case .uuid: return "uuid"
        case .diff: return "diff"
        }
    }

    /// Consume exactly one separator; the remaining whitespace is user data.
    static func match(_ query: String) -> (tool: Self, input: String)? {
        let query = query.drop(while: { $0.isWhitespace })
        for tool in allCases.sorted(by: { $0.command.count > $1.command.count }) {
            guard query.lowercased().hasPrefix(tool.command) else { continue }
            let rest = query.dropFirst(tool.command.count)
            if rest.isEmpty { return (tool, "") }
            if rest.first?.isWhitespace == true { return (tool, String(rest.dropFirst())) }
        }
        return nil
    }
}

enum CommandBarDeveloperError: Error, Equatable {
    case inputTooLarge, invalidJSON, invalidBase64, invalidUTF8, invalidURL, invalidTimestamp, diffTooLarge
}

enum CommandBarDeveloperSupport {
    static let maximumInputBytes = 256 * 1024

    static let maximumJSONInputBytes = 50 * 1024 * 1024

    static func inputLimit(for tool: CommandBarDeveloperTool) -> Int {
        tool == .json || tool == .jsonMinify ? maximumJSONInputBytes : maximumInputBytes
    }

    static func transform(_ tool: CommandBarDeveloperTool, input: String,
                          second: String = "", now: Date = Date()) throws -> String {
        guard input.utf8.count <= inputLimit(for: tool), second.utf8.count <= inputLimit(for: tool) else {
            throw CommandBarDeveloperError.inputTooLarge
        }
        switch tool {
        case .json, .jsonMinify:
            do {
                let object = try JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed])
                var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
                if tool == .json { options.insert(.prettyPrinted) }
                return String(decoding: try JSONSerialization.data(withJSONObject: object, options: options), as: UTF8.self)
            } catch { throw CommandBarDeveloperError.invalidJSON }
        case .base64Encode:
            return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            let value = input.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: value) else { throw CommandBarDeveloperError.invalidBase64 }
            guard let text = String(data: data, encoding: .utf8) else { throw CommandBarDeveloperError.invalidUTF8 }
            return text
        case .urlEncode:
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let value = input.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                throw CommandBarDeveloperError.invalidURL
            }
            return value
        case .urlDecode:
            guard let value = input.removingPercentEncoding else { throw CommandBarDeveloperError.invalidURL }
            return value
        case .uuid:
            return UUID().uuidString.lowercased()
        case .timestamp:
            return try timestamp(input, now: now)
        case .diff:
            return try diff(input, second)
        }
    }

    private static func timestamp(_ input: String, now: Date) throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var milliseconds: Bool?
        if text.hasPrefix("ms:") { milliseconds = true; text = String(text.dropFirst(3)) }
        else if text.hasPrefix("s:") { milliseconds = false; text = String(text.dropFirst(2)) }
        let date: Date
        if text.isEmpty && milliseconds == nil {
            date = now
        } else if let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite {
            let seconds = (milliseconds ?? (abs(number) >= 100_000_000_000)) ? number / 1000 : number
            guard (-62_135_596_800...253_402_300_799).contains(seconds) else {
                throw CommandBarDeveloperError.invalidTimestamp
            }
            date = Date(timeIntervalSince1970: seconds)
        } else {
            guard milliseconds == nil else { throw CommandBarDeveloperError.invalidTimestamp }
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = parser.date(from: text)
            parser.formatOptions = [.withInternetDateTime]
            guard let parsed = fractional ?? parser.date(from: text) else {
                throw CommandBarDeveloperError.invalidTimestamp
            }
            date = parsed
        }
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        utc.timeZone = TimeZone(secondsFromGMT: 0)
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        return "Unix (s): \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), date.timeIntervalSince1970))\nUnix (ms): \(Int64((date.timeIntervalSince1970 * 1000).rounded()))\nUTC: \(utc.string(from: date))\nLocal: \(local.string(from: date))"
    }

    /// Bounded line LCS; duplicates and trailing newlines remain significant.
    static func diff(_ before: String, _ after: String) throws -> String {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")
        guard a.count <= 2000, b.count <= 2000, a.count * b.count <= 2_000_000 else {
            throw CommandBarDeveloperError.diffTooLarge
        }
        let width = b.count + 1
        var lengths = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i * width + j] = a[i] == b[j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var result = ["--- before", "+++ after"]
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append("  " + a[i]); i += 1; j += 1
            } else if i < a.count && (j == b.count || lengths[(i + 1) * width + j] >= lengths[i * width + j + 1]) {
                result.append("- " + a[i]); i += 1
            } else {
                result.append("+ " + b[j]); j += 1
            }
        }
        return result.joined(separator: "\n")
    }
}
