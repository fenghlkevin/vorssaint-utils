// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

@MainActor
final class ProxyWindowController {
    static let shared = ProxyWindowController()
    private var window: NSWindow?
    func show(page: Int = 0) {
        ProxyService.shared.telemetry.selectedPage = page
        guard AppFeature.networkProxy.isAvailable else { return }
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Vorssaint · 网络代理"
            created.contentView = NSHostingView(rootView: ProxyWorkspaceView())
            created.isReleasedWhenClosed = false; created.center(); window = created
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct ProxySettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label { Text("网络代理") } icon: { ProxyBrandIcon(size: 24) }.font(.title2.bold())
            Text("导入本地 Stash / Clash 配置，通过 Mihomo 管理系统代理、节点和规则。")
            Button("打开代理工作台") { ProxyWindowController.shared.show() }.buttonStyle(.borderedProminent)
            Text("支持 SS、VLESS / Reality、远程规则集、版本回退及可选增强模式。")
                .font(.callout).foregroundStyle(.secondary)
            PanelProxyView().frame(maxWidth: 420, alignment: .leading)
        }.padding(24)
    }
}

struct ProxyWorkspaceView: View {
    @ObservedObject private var service = ProxyService.shared

    @ObservedObject private var telemetry = ProxyService.shared.telemetry
    @ObservedObject private var shortcuts = ProxyShortcutController.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ProxyBrandIcon(size: 32).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("网络代理").font(.title2.bold())
                    Text("\(service.stateText) · \(service.selectedProfile?.name ?? "未选择配置")").foregroundStyle(.secondary)
                }
                Spacer()
                if service.busy { ProgressView().controlSize(.small) }
                if service.state != .stopped {
                    Button("停止并恢复网络") { service.stop() }.disabled(service.state == .stopping)
                } else {
                    Button("启动代理") { service.start() }.buttonStyle(.borderedProminent).disabled(!service.canStart)
                }
            }.padding(24)
            if let error = service.error { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12) }
            TabView(selection: $telemetry.selectedPage) {
                overview.tabItem { Label("概览", systemImage: "gauge.with.dots.needle.33percent") }.tag(0)
                ProxyConnectionsView(telemetry: telemetry).tabItem { Label("连接", systemImage: "link") }.tag(8)
                ProxyLogsView(telemetry: telemetry).tabItem { Label("日志", systemImage: "text.alignleft") }.tag(9)
                ProxyDiagnosticsView(service: service).tabItem { Label("诊断", systemImage: "stethoscope") }.tag(10)
                strategies.tabItem { Label("代理", systemImage: "point.3.connected.trianglepath.dotted") }.tag(1)
                ProxyStructuredEditor(service: service).tabItem { Label("图形编辑", systemImage: "slider.horizontal.3") }.tag(7)
                ProxyRulesEditor(service: service).tabItem { Label("规则", systemImage: "list.number") }.tag(4)
                ProxyResourcesView(service: service).tabItem { Label("资源", systemImage: "externaldrive") }.tag(5)
                profiles.tabItem { Label("配置", systemImage: "doc.text") }.tag(2)
                ProxyNetworkView(service: service).tabItem { Label("网络 / VPN", systemImage: "network.badge.shield.half.filled") }.tag(6)
                settings.tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
            }.padding(16)
        }.frame(minWidth: 1040, minHeight: 720)
        .background(ProxyVisibilityProbe(telemetry: telemetry).frame(width: 0, height: 0))
        .sheet(isPresented: Binding(get: { service.importPreview != nil }, set: { if !$0 { service.importPreview = nil } })) { importSheet }
    }
    private var overview: some View {
        Form {
            ProxyTrafficView(telemetry: telemetry)
            LabeledContent("核心", value: "Mihomo \(ProxyCore.version)")
            LabeledContent("状态", value: service.statusDetail.isEmpty ? service.stateText : service.statusDetail)
            LabeledContent("本机代理", value: "127.0.0.1:\(service.preferences.mixedPort)")
            LabeledContent("系统代理", value: service.systemProxyEffective ? "已启用" : "未接管")
            LabeledContent("配置内容", value: "\(service.inspection?.nodeNames.count ?? 0) 个节点 · \(service.inspection?.groups.count ?? 0) 个策略组 · \(service.inspection?.ruleCount ?? 0) 条规则")
            Picker("出站模式", selection: Binding(get: { service.preferences.mode }, set: service.setMode)) {
                Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
            }.disabled(service.busy)
            Text("直连由 macOS 路由表决定。公司内网和 DNS 是否可达，仍取决于 OpenVPN 连接。系统代理模式不接管所有应用流量。")
                .font(.callout).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private var strategies: some View {
        ScrollView {
            VStack(spacing: 14) {
                if service.groups.isEmpty { Text("导入配置后显示策略组").padding(40) }
                ForEach(service.groups) { group in
                    GroupBox {
                        HStack {
                            Text(group.name).font(.headline)
                            Spacer()
                            Button(service.testingNodes.isEmpty ? "测试延迟" : service.delayTestProgress) { service.test(group.members) }.disabled(!service.testingNodes.isEmpty)
                        }
                        ForEach(group.members, id: \.self) { member in
                            HStack {
                                Image(systemName: group.selected == member ? "checkmark.circle.fill" : "circle").foregroundStyle(group.selected == member ? .blue : .secondary)
                                Text(member)
                                Spacer()
                                ProxyDelayBadge(delay: service.delays[member], testing: service.activeTestingNodes.contains(member), queued: service.testingNodes.contains(member) && !service.activeTestingNodes.contains(member), date: service.delayDates[member], blocked: ["REJECT", "REJECT-DROP"].contains(member))
                                Button("选择") { service.choose(group: group.name, member: member) }.disabled(group.selected == member)
                            }.padding(.vertical, 4)
                        }
                    }.disabled(service.state != .running || service.busy)
                }
            }.padding()
        }
    }
    private var profiles: some View { ProxyProfileEditor(service: service) }
    private func port(_ title: String, _ path: WritableKeyPath<ProxyPreferences, Int>) -> some View {
        TextField(title, value: Binding(get: { service.preferences[keyPath: path] }, set: { value in var updated = service.preferences; updated[keyPath: path] = value; service.savePreferences(updated) }), format: .number.grouping(.never))
            .disabled(service.state != .stopped || service.busy)
    }
    private var settings: some View {
        Form {
            Section("网络") {
                Toggle("设置为系统代理", isOn: Binding(get: { service.state == .running ? service.systemProxyEffective : service.preferences.systemProxy }, set: service.setSystemProxy)).disabled(service.busy)
                Toggle("允许局域网访问", isOn: Binding(get: { service.preferences.allowLAN }, set: service.setLAN)).disabled(service.busy)
                Text("修改局域网访问会重启核心。开启后，局域网设备可使用本机代理端口。Controller 始终只监听本机。")
                    .font(.caption).foregroundStyle(.secondary)
                port("代理端口", \.mixedPort); port("Controller 端口", \.controllerPort); port("DNS 端口", \.dnsPort)
                Toggle("允许唯一匹配的策略名称大小写修复", isOn: Binding(get: { service.preferences.repairReferences }, set: { value in var updated = service.preferences; updated.repairReferences = value; service.savePreferences(updated) })).disabled(service.state != .stopped || service.busy)
            }
            Section("启动与终端") {
                Toggle("Vorssaint 启动时自动启动代理", isOn: Binding(get: { service.preferences.autoStart }, set: service.setAutoStart))
                Text("退出 Vorssaint 后代理继续运行；断开连接请点击停止代理。").font(.caption).foregroundStyle(.secondary)
                HStack { Button("复制 Shell 代理命令") { service.copyShell() }; Button("复制取消代理命令") { service.copyUnset() } }
                Menu("使用局域网 IP 复制 Shell 命令") {
                    ForEach((try? NetworkInfoLocalAddresses.read())?.filter { !$0.isTunnel } ?? []) { address in
                        Button("\(address.interface) · \(address.ip)") { service.copyShell(host: address.ip) }
                    }
                }.disabled(!service.preferences.allowLAN)
            }
            Section("快捷键") {
                Text("在 Vorssaint 设置 → 快捷键 → 网络代理中配置工作台、系统代理切换和重载快捷键，默认关闭。")
                if shortcuts.registrationFailed { Text("快捷键注册失败，请更换被占用的组合。").foregroundStyle(.red) }
            }
            Text("增强模式、路由预检与公司检测位于“网络 / VPN”页。").foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入配置 · \(service.importName)").font(.title2)
            if let preview = service.importPreview {
                Text("\(preview.nodeNames.count) 个节点 · \(preview.groups.count) 个策略组 · \(preview.ruleCount) 条规则")
                ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(preview.issues) { issue in Text(issue.message).foregroundStyle(issue.severity == .error ? .red : .primary).frame(maxWidth: .infinity, alignment: .leading) } } }.frame(maxHeight: 260)
                if preview.issues.contains(where: { $0.severity == .repair }) { Toggle("确认修复唯一匹配的策略名称引用", isOn: $service.confirmRepairs) }
                HStack { Spacer(); Button("取消") { service.importPreview = nil }; Button("导入") { service.confirmImport() }.buttonStyle(.borderedProminent).disabled(preview.hasErrors || preview.issues.contains(where: { $0.severity == .repair }) && !service.confirmRepairs) }
            }
        }.padding(24).frame(width: 580)
    }
}
