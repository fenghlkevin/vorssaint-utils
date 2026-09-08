// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CommandBarDeveloperText {
    static func text(_ chinese: String, _ english: String) -> String {
        switch L10n.shared.language {
        case .zhHans, .zhTW, .zhHK: return chinese
        default: return english
        }
    }
}

extension CommandBarDeveloperTool {
    var launcherTitle: String {
        if self == .json { return CommandBarDeveloperText.text("内部 JSON 工具", "Built-in JSON tool") }
        return CommandBarDeveloperText.text("内部工具 · \(title)", "Built-in tool · \(title)")
    }

    var title: String {
        let names: (String, String)
        switch self {
        case .json: names = ("JSON 格式化", "Format JSON")
        case .jsonMinify: names = ("JSON 压缩", "Minify JSON")
        case .base64Encode: names = ("Base64 编码", "Encode Base64")
        case .base64Decode: names = ("Base64 解码", "Decode Base64")
        case .urlEncode: names = ("URL 编码", "Encode URL component")
        case .urlDecode: names = ("URL 解码", "Decode URL component")
        case .timestamp: names = ("时间戳转换", "Convert timestamp")
        case .uuid: names = ("生成 UUID", "Generate UUID")
        case .diff: names = ("文本差异比较", "Compare text")
        }
        return CommandBarDeveloperText.text(names.0, names.1)
    }

    var hint: String {
        switch self {
        case .timestamp:
            return CommandBarDeveloperText.text("秒 / 毫秒 / 带时区的 ISO 8601；留空使用当前时间。可用 s: 或 ms: 指定单位。",
                "Seconds / milliseconds / ISO 8601 with time zone. Empty = now. Use s: or ms: for explicit units.")
        case .urlEncode, .urlDecode:
            return CommandBarDeveloperText.text("按 URL 参数值编码，空格使用 %20；解码时 + 不转为空格。",
                "URL component encoding: spaces use %20; + remains a plus when decoding.")
        case .base64Decode:
            return CommandBarDeveloperText.text("标准 Base64 → UTF-8 文本；允许换行和空白。", "Standard Base64 → UTF-8 text; whitespace is allowed.")
        case .diff:
            return CommandBarDeveloperText.text("逐行比较：− 删除，+ 新增；保留空白和末尾换行差异。", "Line comparison: − removed, + added; whitespace and final newlines matter.")
        default:
            return CommandBarDeveloperText.text("在本机处理，不保存输入；可输入多行文本或从剪贴板粘贴。", "Processed locally without saving input. Type multiline text or paste from the clipboard.")
        }
    }
}

extension CommandBarDeveloperError {
    var message: String {
        switch self {
        case .inputTooLarge: return CommandBarDeveloperText.text("JSON 输入最多 50 MB，其他工具每份输入最多 256 KB。", "JSON input is limited to 50 MB; other tools to 256 KB.")
        case .invalidJSON: return CommandBarDeveloperText.text("JSON 格式无效，请检查引号、逗号和括号。", "Invalid JSON. Check quotes, commas and brackets.")
        case .invalidBase64: return CommandBarDeveloperText.text("不是有效的标准 Base64 文本。", "Invalid standard Base64 text.")
        case .invalidUTF8: return CommandBarDeveloperText.text("解码结果是二进制数据，无法作为 UTF-8 文本显示。", "The decoded data is not UTF-8 text.")
        case .invalidURL: return CommandBarDeveloperText.text("URL 百分号编码无效或不是 UTF-8 文本。", "Invalid percent encoding or non-UTF-8 text.")
        case .invalidTimestamp: return CommandBarDeveloperText.text("请输入有效秒/毫秒时间戳，或带时区的 ISO 8601 日期。", "Enter valid seconds/milliseconds or an ISO 8601 date with a time zone.")
        case .diffTooLarge: return CommandBarDeveloperText.text("文本行数过多，请缩小比较范围（每份最多 2000 行，行数乘积最多 200 万）。", "Reduce the comparison: at most 2,000 lines per input and 2 million line pairs.")
        }
    }
}

final class CommandBarDeveloperSession: ObservableObject {
    @Published var tool: CommandBarDeveloperTool = .json { didSet { invalidate() } }
    @Published var input = "" { didSet { invalidate() } }
    @Published var secondInput = "" { didSet { invalidate() } }
    @Published private(set) var output: String?
    @Published private(set) var jsonDocument: CommandBarJSONDocument?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var copied = false
    private var generation = UUID()
    private let queue = DispatchQueue(label: "Vorssaint.commandBar.textTools", qos: .userInitiated)

    func reset() {
        input = ""
        secondInput = ""
        invalidate()
    }

    private func invalidate() {
        generation = UUID()
        output = nil
        jsonDocument = nil
        error = nil
        busy = false
        copied = false
    }

    func open(_ tool: CommandBarDeveloperTool, input: String) {
        reset()
        self.tool = tool
        guard input.utf8.count <= CommandBarDeveloperSupport.inputLimit(for: tool) else {
            error = CommandBarDeveloperError.inputTooLarge.message
            return
        }
        self.input = input
        if tool != .diff && (!input.isEmpty || tool == .uuid || tool == .timestamp) { run() }
    }

    func paste(second: Bool = false) {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        guard value.utf8.count <= CommandBarDeveloperSupport.inputLimit(for: tool) else {
            error = CommandBarDeveloperError.inputTooLarge.message
            return
        }
        if second { secondInput = value } else { input = value }
    }

    func run() {
        guard !busy, CommandBarBuiltinSettings.isEnabled(tool) else { return }
        invalidate()
        busy = true
        let token = generation
        let tool = tool, input = input, second = secondInput
        queue.async { [weak self] in
            let result = Result { () throws -> (String, CommandBarJSONDocument?) in
                let output = try CommandBarDeveloperSupport.transform(tool, input: input, second: second)
                let document = tool == .json || tool == .jsonMinify ? try CommandBarJSONDocument(text: output) : nil
                return (output, document)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.busy = false
                switch result {
                case .success(let value): self.output = value.0; self.jsonDocument = value.1
                case .failure(let error): self.error = (error as? CommandBarDeveloperError)?.message ?? error.localizedDescription
                }
            }
        }
    }

    func openJSONFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.invalidate()
            self.busy = true
            let token = self.generation
            self.queue.async { [weak self] in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let result = Result { () throws -> String in
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let limit = CommandBarDeveloperSupport.maximumJSONInputBytes
                    var data = Data()
                    while let chunk = try handle.read(upToCount: min(1024 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
                        data.append(chunk)
                        guard data.count <= limit else { throw CommandBarDeveloperError.inputTooLarge }
                    }
                    guard let text = String(data: data, encoding: .utf8) else { throw CommandBarDeveloperError.invalidUTF8 }
                    return text
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.busy = false
                    switch result {
                    case .success(let text): self.input = text; self.run()
                    case .failure(let error): self.error = (error as? CommandBarDeveloperError)?.message ?? error.localizedDescription
                    }
                }
            }
        }
    }

    func copy() {
        guard let output else { return }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(output, forType: .string)
    }
}

struct CommandBarDeveloperView: View {
    @ObservedObject var session: CommandBarDeveloperSession
    @AppStorage(DefaultsKey.commandBarBuiltinTools) private var builtinToolsRaw = "{}"
    private let t = CommandBarDeveloperText.text
    @State private var editLargeInput = false

    private var enabledTools: [CommandBarDeveloperTool] {
        let settings = CommandBarBuiltinPreferences.decode(builtinToolsRaw)
        return CommandBarBuiltinTool.allCases.filter {
            CommandBarBuiltinPreferences.configuration($0, in: settings).enabled
        }.compactMap(\.textTool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(Color.accentColor)
                Text(t("内部工具", "Built-in tools")).font(.headline)
                Picker(t("开发者工具", "Developer tools"), selection: $session.tool) {
                    ForEach(enabledTools) { tool in Text(tool.title).tag(tool) }
                    if !enabledTools.contains(session.tool) {
                        Text(session.tool.title + t("（已关闭）", " (disabled)")).tag(session.tool)
                    }
                }.labelsHidden()
                Spacer()
                Button(t("清空", "Clear")) { session.reset() }
            }
            Text(session.tool.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !enabledTools.contains(session.tool) {
                Text(t("此工具已在设置中关闭；编辑内容保留，重新启用后可继续运行。", "This tool is disabled in Settings. Your text is kept; re-enable it to run again."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if session.tool != .uuid {
                HStack(alignment: .top, spacing: 10) {
                    editor(t(session.tool == .diff ? "原文" : "输入", session.tool == .diff ? "Before" : "Input"),
                           value: $session.input, second: false)
                    if session.tool == .diff { editor(t("新文本", "After"), value: $session.secondInput, second: true) }
                }
            }
            HStack {
                Button(t("运行 ⇧↩", "Run ⇧↩")) { session.run() }.disabled(session.busy || !enabledTools.contains(session.tool))
                if session.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(session.copied ? t("已复制", "Copied") : t("复制结果", "Copy result")) { session.copy() }
                    .disabled(session.output == nil)
            }
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let document = session.jsonDocument {
                CommandBarJSONResultView(document: document)
                    .frame(minHeight: 180, maxHeight: .infinity)
            } else {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Text(preview)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(minWidth: max(0, geometry.size.width - 16), alignment: .topLeading)
                        .padding(8)
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            if session.jsonDocument == nil, let output = session.output, output.count > 24_000 {
                Text(t("仅预览前 24000 字符；复制可获得完整结果。", "Preview shows 24,000 characters; Copy includes the full result.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 500)
    }

    private func editor(_ label: String, value: Binding<String>, second: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                if !second && (session.tool == .json || session.tool == .jsonMinify) {
                    Button(t("打开文件…", "Open file…")) { session.openJSONFile() }.controlSize(.small).disabled(session.busy)
                }
                Button(t("粘贴", "Paste")) { session.paste(second: second) }.controlSize(.small)
            }
            if value.wrappedValue.utf8.count > 1024 * 1024 && !editLargeInput {
                HStack {
                    Text(t("已载入大文件", "Large input loaded") + " · " + ByteCountFormatter.string(fromByteCount: Int64(value.wrappedValue.utf8.count), countStyle: .file))
                    Spacer()
                    Button(t("编辑原文", "Edit source")) { editLargeInput = true }
                }.padding(10)
            } else {
            CommandBarDeveloperTextEditor(text: value, focusOnAppear: !second)
                .frame(minHeight: 160, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
                .accessibilityLabel(label)
            }
        }
    }

    private var preview: AttributedString {
        guard let output = session.output else { return AttributedString(t("结果将在这里显示", "Results appear here")) }
        let text = String(output.prefix(24_000))
        guard session.tool == .diff else { return AttributedString(text) }
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            var part = AttributedString((index == 0 ? "" : "\n") + line)
            if line.hasPrefix("- ") { part.foregroundColor = .red }
            if line.hasPrefix("+ ") { part.foregroundColor = .green }
            result.append(part)
        }
        return result
    }
}

/// Code input must not silently turn ASCII quotes/dashes into typography.
private struct CommandBarDeveloperTextEditor: NSViewRepresentable {
    @Binding var text: String
    let focusOnAppear: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.delegate = context.coordinator
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.isHorizontallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 5, height: 6)
        if focusOnAppear {
            DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        // A replaced input (paste/clear/tool change) cannot undo into an old session.
        editor.undoManager?.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandBarDeveloperTextEditor
        init(_ parent: CommandBarDeveloperTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
