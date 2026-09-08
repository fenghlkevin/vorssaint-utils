// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

extension CommandBarCatalog {
    static func developerEntries() -> [CommandBarEntry] {
        var entries = CommandBarDeveloperTool.allCases.filter { CommandBarBuiltinSettings.isEnabled($0) }.map { developerEntry($0) }
        if CommandBarBuiltinSettings.isEnabled(CommandBarBuiltinTool.port) {
            let trigger = CommandBarBuiltinSettings.trigger(.port)
            entries.append(
            CommandBarEntry(id: "action.portLookup", title: CommandBarDeveloperText.text("端口占用查询", "Find port owners"),
                subtitle: "\(trigger) 8080 · TCP / UDP", keywords: "\(trigger) 端口 占用 强制 结束 kill process developer 开发者",
                icon: .symbol("network"), keepsBarOpen: true) { _ in
                    guard CommandBarBuiltinSettings.isEnabled(CommandBarBuiltinTool.port) else { return }
                    CommandBarService.shared.prefill(CommandBarBuiltinSettings.trigger(.port) + " ")
                })
        }
        return entries
    }

    static func developerEntry(_ tool: CommandBarDeveloperTool) -> CommandBarEntry {
        let builtin = CommandBarBuiltinTool(rawValue: tool.rawValue)!
        let trigger = CommandBarBuiltinSettings.trigger(builtin)
        return CommandBarEntry(id: builtin.rowID, title: tool.launcherTitle,
            subtitle: CommandBarDeveloperText.text("快捷输入：\(trigger) · 打开独立编辑器", "Trigger: \(trigger) · Open tool editor"),
            keywords: "\(trigger) \(tool.title) developer 开发者 文本 工具 内部 app", icon: .symbol("chevron.left.forwardslash.chevron.right"),
            countsUsage: false, takesArgument: true) { _ in
                let service = CommandBarService.shared
                guard CommandBarBuiltinSettings.isEnabled(tool) else { return }
                let match = CommandBarBuiltinSettings.matchText(service.queryWhenRun)
                let argument = match?.tool == tool ? match?.input ?? "" : ""
                DeveloperToolsWindowController.shared.show(tool: tool, input: argument)
            }
    }
}
