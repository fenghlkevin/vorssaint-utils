// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum CommandBarBuiltinSettings {
    static var current: CommandBarBuiltinPreferences.Settings {
        CommandBarBuiltinPreferences.decode(UserDefaults.standard.string(forKey: DefaultsKey.commandBarBuiltinTools) ?? "{}")
    }

    static func isEnabled(_ tool: CommandBarBuiltinTool) -> Bool {
        CommandBarBuiltinPreferences.configuration(tool, in: current).enabled
    }

    static func isEnabled(_ tool: CommandBarDeveloperTool) -> Bool {
        guard let builtin = CommandBarBuiltinTool(rawValue: tool.rawValue) else { return false }
        return isEnabled(builtin)
    }

    static func trigger(_ tool: CommandBarBuiltinTool) -> String {
        CommandBarBuiltinPreferences.configuration(tool, in: current).trigger
    }

    static func matchText(_ query: String) -> (tool: CommandBarDeveloperTool, input: String)? {
        guard let match = CommandBarBuiltinPreferences.match(query, in: current), let tool = match.tool.textTool else { return nil }
        return (tool, match.input)
    }
}
