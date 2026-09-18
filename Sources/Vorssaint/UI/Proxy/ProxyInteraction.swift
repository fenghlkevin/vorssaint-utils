// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

@MainActor final class ProxyShortcutController: ObservableObject {
    static let shared = ProxyShortcutController()
    @Published private(set) var registrationFailed = false
    private let open = QuickToolHotkey(id: 1901)
    private let toggle = QuickToolHotkey(id: 1902)
    private let reload = QuickToolHotkey(id: 1903)
    private init() {
        open.onPress = { ProxyWindowController.shared.show() }
        toggle.onPress = {
            let service = ProxyService.shared
            guard AppFeature.networkProxy.isAvailable, service.state == .running, !service.busy else { return }
            service.setSystemProxy(!service.systemProxyEffective)
        }
        reload.onPress = {
            guard AppFeature.networkProxy.isAvailable else { return }
            ProxyService.shared.reloadProfile()
        }
    }
    func sync() {
        registrationFailed = false
        for (key, role) in [(open, GlobalShortcutRole.proxyOpen), (toggle, .proxySystem), (reload, .proxyReload)] {
            let enabled = AppFeature.networkProxy.isAvailable && UserDefaults.standard.bool(forKey: role.requiredEnableKeys[0])
            if !key.sync(enabled: enabled, shortcut: role.savedShortcut) { registrationFailed = true }
        }
    }
}

struct ProxyDiagnosticsView: View {
    @ObservedObject var service: ProxyService
    @State private var preview = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("诊断报告").font(.headline)
            Text("仅包含版本、运行状态、端口、配置条目数量和流量统计。不会包含 YAML、配置名称、节点凭据、域名/IP、连接记录或日志正文。").foregroundStyle(.secondary)
            HStack { Button("生成 / 刷新预览") { refresh() }; Button("导出已预览报告") { export() }.disabled(preview.isEmpty) }
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView { Text(preview.isEmpty ? "点击生成，先检查内容再导出。" : preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Text("TUN 实机验证暂缓。当前为开发签名构建；正式分发、公证和长期实机稳定性验收另行进行。").font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
    private func refresh() { do { preview = String(decoding: try service.diagnosticData(), as: UTF8.self); error = nil } catch { self.error = error.localizedDescription } }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "vorssaint-proxy-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(preview.utf8).write(to: url, options: .atomic); error = nil } catch { self.error = error.localizedDescription }
    }
}
