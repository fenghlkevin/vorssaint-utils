// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum CommandBarBuiltinTool: String, CaseIterable, Identifiable {
    case json, jsonMinify, base64Encode, base64Decode, urlEncode, urlDecode, timestamp, uuid, diff, port

    var id: String { rawValue }
    var textTool: CommandBarDeveloperTool? { CommandBarDeveloperTool(rawValue: rawValue) }
    var defaultTrigger: String { textTool?.command ?? "port" }
    var rowID: String { self == .port ? "action.portLookup" : "action.developer.\(rawValue)" }
}

struct CommandBarBuiltinConfiguration: Codable, Equatable {
    var enabled: Bool
    var trigger: String
}

enum CommandBarBuiltinPreferences {
    typealias Settings = [CommandBarBuiltinTool: CommandBarBuiltinConfiguration]
    enum Validation: Equatable { case invalidFormat, duplicate(CommandBarBuiltinTool) }

    static var defaults: Settings {
        Dictionary(uniqueKeysWithValues: CommandBarBuiltinTool.allCases.map {
            ($0, CommandBarBuiltinConfiguration(enabled: true, trigger: $0.defaultTrigger))
        })
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func validTrigger(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (1...32).contains(trimmed.count), trimmed.first?.isLetter == true,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" }) else { return nil }
        return normalized(trimmed)
    }

    static func validation(_ trigger: String, for tool: CommandBarBuiltinTool, in settings: Settings) -> Validation? {
        guard let value = validTrigger(trigger) else { return .invalidFormat }
        if let duplicate = CommandBarBuiltinTool.allCases.first(where: {
            $0 != tool && configuration($0, in: settings).trigger == value
        }) { return .duplicate(duplicate) }
        return nil
    }

    static func configuration(_ tool: CommandBarBuiltinTool, in settings: Settings) -> CommandBarBuiltinConfiguration {
        settings[tool] ?? CommandBarBuiltinConfiguration(enabled: true, trigger: tool.defaultTrigger)
    }

    static func decode(_ raw: String) -> Settings {
        guard raw.utf8.count <= 32_768,
              let saved = try? JSONDecoder().decode([String: CommandBarBuiltinConfiguration].self, from: Data(raw.utf8)) else { return defaults }
        var result = defaults
        for tool in CommandBarBuiltinTool.allCases {
            guard let value = saved[tool.rawValue] else { continue }
            result[tool] = .init(enabled: value.enabled, trigger: validTrigger(value.trigger) ?? tool.defaultTrigger)
        }
        // Edited/imported files must not make one trigger launch two tools.
        // Keep enable switches, but restore known-unique triggers on collision.
        if Set(result.values.map(\.trigger)).count != result.count {
            for tool in CommandBarBuiltinTool.allCases { result[tool]?.trigger = tool.defaultTrigger }
        }
        return result
    }

    static func encode(_ settings: Settings) -> String {
        let values = Dictionary(uniqueKeysWithValues: settings.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(values)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Longest configured trigger wins; a disabled longer trigger never falls
    /// through to a shorter tool. Arguments keep their original whitespace.
    static func match(_ text: String, in settings: Settings) -> (tool: CommandBarBuiltinTool, input: String)? {
        let text = text.drop(while: \.isWhitespace)
        let ordered = CommandBarBuiltinTool.allCases.sorted {
            let left = configuration($0, in: settings).trigger
            let right = configuration($1, in: settings).trigger
            return left.count == right.count ? $0.rawValue < $1.rawValue : left.count > right.count
        }
        for tool in ordered {
            let config = configuration(tool, in: settings)
            guard text.prefix(config.trigger.count).lowercased() == config.trigger else { continue }
            let rest = text.dropFirst(config.trigger.count)
            guard rest.isEmpty || rest.first?.isWhitespace == true else { continue }
            guard config.enabled else { return nil }
            return (tool, rest.isEmpty ? "" : String(rest.dropFirst()))
        }
        return nil
    }

    static func portQuery(_ text: String, in settings: Settings) -> String? {
        if let match = match(text, in: settings) { return match.tool == .port ? "port " + match.input : nil }
        let port = configuration(.port, in: settings)
        if port.enabled, port.trigger == "port", text.split(whereSeparator: \.isWhitespace).first == "端口" {
            return "port " + text.drop(while: \.isWhitespace).dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
