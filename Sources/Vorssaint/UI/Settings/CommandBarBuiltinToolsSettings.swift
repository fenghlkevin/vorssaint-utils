// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

extension CommandBarBuiltinTool {
    var displayName: String {
        textTool?.title ?? CommandBarDeveloperText.text("端口占用查询", "Find port owners")
    }
}

struct CommandBarBuiltinToolsSettings: View {
    @AppStorage(DefaultsKey.commandBarBuiltinTools) private var raw = "{}"
    var onChange: () -> Void = {}
    private let t = CommandBarDeveloperText.text
    private var settings: CommandBarBuiltinPreferences.Settings { CommandBarBuiltinPreferences.decode(raw) }

    var body: some View {
        Section {
            ForEach(CommandBarBuiltinTool.allCases) { tool in
                CommandBarBuiltinToolRow(tool: tool, settings: settings,
                    setEnabled: { enabled in
                        var next = settings
                        var config = CommandBarBuiltinPreferences.configuration(tool, in: next)
                        config.enabled = enabled
                        next[tool] = config
                        raw = CommandBarBuiltinPreferences.encode(next)
                    }, saveTrigger: { trigger in
                        var next = settings
                        guard CommandBarBuiltinPreferences.validation(trigger, for: tool, in: next) == nil,
                              let trigger = CommandBarBuiltinPreferences.validTrigger(trigger) else { return }
                        var config = CommandBarBuiltinPreferences.configuration(tool, in: next)
                        config.trigger = trigger
                        next[tool] = config
                        raw = CommandBarBuiltinPreferences.encode(next)
                    })
            }
        } header: {
            Text(t("内部小应用", "Built-in mini apps"))
        } footer: {
            Text(t("每个工具可独立开关。快捷输入是命令栏中的触发词，例如 json 或 jsonx；修改后点击保存。关闭的工具不再出现在搜索结果中。",
                   "Enable each tool independently. A text trigger, such as json or jsonx, opens it from search. Save after editing. Disabled tools are removed from results."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: raw) { _, _ in onChange() }
    }
}

private struct CommandBarBuiltinToolRow: View {
    let tool: CommandBarBuiltinTool
    let settings: CommandBarBuiltinPreferences.Settings
    let setEnabled: (Bool) -> Void
    let saveTrigger: (String) -> Void
    @State private var draft: String
    private let t = CommandBarDeveloperText.text

    init(tool: CommandBarBuiltinTool, settings: CommandBarBuiltinPreferences.Settings,
         setEnabled: @escaping (Bool) -> Void, saveTrigger: @escaping (String) -> Void) {
        self.tool = tool
        self.settings = settings
        self.setEnabled = setEnabled
        self.saveTrigger = saveTrigger
        _draft = State(initialValue: CommandBarBuiltinPreferences.configuration(tool, in: settings).trigger)
    }

    private var config: CommandBarBuiltinConfiguration {
        CommandBarBuiltinPreferences.configuration(tool, in: settings)
    }

    private var validation: CommandBarBuiltinPreferences.Validation? {
        CommandBarBuiltinPreferences.validation(draft, for: tool, in: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(tool.displayName, isOn: Binding(get: { config.enabled }, set: setEnabled))
            HStack(spacing: 8) {
                Text(t("快捷输入", "Text trigger")).font(.caption).foregroundStyle(.secondary)
                TextField(tool.defaultTrigger, text: $draft)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .frame(width: 220)
                    .disableAutocorrection(true)
                    .accessibilityLabel(tool.displayName + " " + t("快捷输入", "text trigger"))
                    .onSubmit(commit)
                Button(t("保存", "Save"), action: commit)
                    .disabled(draft == config.trigger || validation != nil)
                if draft != tool.defaultTrigger {
                    Button(t("恢复默认", "Use default")) { draft = tool.defaultTrigger; commit() }
                        .disabled(CommandBarBuiltinPreferences.validation(tool.defaultTrigger, for: tool, in: settings) != nil)
                }
                Spacer(minLength: 0)
            }
            if let validation {
                Text(message(validation)).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3)
        .onChange(of: config.trigger) { _, trigger in draft = trigger }
    }

    private func commit() {
        guard validation == nil, let trigger = CommandBarBuiltinPreferences.validTrigger(draft) else { return }
        saveTrigger(trigger)
        draft = trigger
    }

    private func message(_ validation: CommandBarBuiltinPreferences.Validation) -> String {
        switch validation {
        case .invalidFormat:
            return t("使用 1–32 个字符，以文字开头；支持文字、数字、空格、_ 和 -。", "Use 1–32 characters starting with a letter: letters, digits, spaces, _ and -.")
        case .duplicate(let other):
            return t("该触发词已被“\(other.displayName)”使用。", "This trigger is already used by \(other.displayName).")
        }
    }
}
