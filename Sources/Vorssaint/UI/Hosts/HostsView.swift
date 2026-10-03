// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

@MainActor final class HostsWindowController {
    static let shared = HostsWindowController()
    private var window: NSWindow?
    func show() {
        guard AppFeature.hosts.isAvailable else { return }
        HostsService.shared.refresh()
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Vorssaint · Hosts 管理"
            created.contentView = NSHostingView(rootView: HostsWorkspaceView())
            created.isReleasedWhenClosed = false; created.center(); window = created
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func close() { window?.close(); window = nil; HostsService.loaded?.closeConnection() }
}

struct HostsSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Hosts 管理", systemImage: "server.rack").font(.title2.bold())
            Text("管理本地 Hosts 配置，组合启用并快速切换开发环境。")
            Button("打开 Hosts 工作台") { HostsWindowController.shared.show() }.buttonStyle(.borderedProminent)
            Text("只修改 Vorssaint 管理区块，保留系统原有内容。应用前自动备份，写入需要授权网络助手。退出应用或卸载本模块不会移除已应用的映射；请先在工作台点击“停用全部”。")
                .foregroundStyle(.secondary)
        }.padding(24)
    }
}

struct PanelHostsView: View {
    @ObservedObject private var service = HostsService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Hosts 管理", systemImage: "server.rack").font(.headline)
                Spacer()
                Button("管理") { HostsWindowController.shared.show() }
            }
            Text(service.pending ? "配置待应用 · 系统已应用内容请在工作台查看" : service.managedContent.isEmpty ? "未启用映射" : "组合已应用").font(.caption).foregroundStyle(.secondary)
            ForEach(service.profiles) { profile in
                Toggle(profile.name, isOn: Binding(get: { profile.enabled }, set: { service.select(profile.id, enabled: $0, applyImmediately: true) }))
                    .disabled(service.busy || !service.hasSnapshot)
            }
            if service.profiles.isEmpty { Text("添加本地配置后即可快速切换。").foregroundStyle(.secondary) }
            if !service.message.isEmpty { Text(service.message).font(.caption).textSelection(.enabled) }
            HStack {
                Button("刷新") { service.refresh() }
                Button("停用全部") { service.disable() }.disabled(!service.canDisable)
                if service.busy { ProgressView().controlSize(.small) }
            }
        }.padding(12).onAppear { service.refresh() }
    }
}

struct HostsWorkspaceView: View {
    @ObservedObject private var service = HostsService.shared
    @State private var selected: UUID?
    @State private var editing: HostsProfile?
    @State private var deleting: HostsProfile?
    @State private var restoring: HostsBackup?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Hosts 管理", systemImage: "server.rack").font(.title2.bold())
                Spacer()
                Text(service.pending ? "配置待应用" : "已同步系统 Hosts").foregroundStyle(.secondary)
                if service.busy { ProgressView().controlSize(.small) }
                Button("刷新") { service.refresh() }
                Button("应用组合") { service.apply() }.buttonStyle(.borderedProminent).disabled(!service.canApply)
                Button("停用全部") { service.disable() }.disabled(!service.canDisable)
            }
            HStack {
                Text("网络助手：\(service.access)").foregroundStyle(.secondary)
                Button("授权 / 更新助手") { service.authorize() }
                Text("配置退出后继续生效").font(.caption).foregroundStyle(.secondary)
            }
            if !service.message.isEmpty { Text(service.message).font(.callout).textSelection(.enabled) }
            TabView {
                configurations.tabItem { Label("本地配置", systemImage: "doc.text") }
                textView(service.systemContent).tabItem { Label("系统 Hosts", systemImage: "desktopcomputer") }
                history.tabItem { Label("备份与恢复", systemImage: "clock.arrow.circlepath") }
            }
            Text("保留 /etc/hosts 原有内容，仅维护 Vorssaint 区块。使用自定义 DNS、代理远端解析或 TUN 时，应用可能绕过系统 Hosts。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 880, minHeight: 620)
        .disabled(service.busy)
        .sheet(item: $editing) { profile in HostsProfileEditor(service: service, profile: profile) }
        .alert("删除配置？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let deleting { service.delete(deleting.id) }; deleting = nil }
        } message: { Text("删除后请应用组合，使系统中的内容同步更新。") }
        .alert("恢复这份备份？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("取消", role: .cancel) { restoring = nil }
            Button("恢复") { if let restoring { service.restore(restoring) }; restoring = nil }
        } message: { Text("仅恢复备份中的 Vorssaint 管理区块，保留当前系统的其他记录。原配置会保留并停用；恢复前自动保存新备份。") }
        .onAppear { service.refresh() }
    }
    private var configurations: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("组合配置").font(.headline)
                    Spacer()
                    Button { editing = HostsProfile(name: "新配置", content: "# IP 地址  域名\n127.0.0.1 app.test\n") } label: { Image(systemName: "plus") }.help("新增配置")
                }
                List(selection: $selected) {
                    ForEach(service.profiles) { profile in
                        HStack {
                            Toggle("", isOn: Binding(get: { profile.enabled }, set: { service.select(profile.id, enabled: $0) })).labelsHidden()
                            Text(profile.name).lineLimit(1)
                        }.tag(profile.id)
                        .contextMenu {
                            Button("编辑") { editing = profile }
                            Button("复制") { var copy = profile; copy.id = UUID(); copy.name += " 副本"; copy.enabled = false; editing = copy }
                            Button("删除", role: .destructive) { deleting = profile }
                        }
                    }
                }
                Text("勾选多个配置后点击“应用组合”。").font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
            VStack(alignment: .leading, spacing: 10) {
                if let profile = service.profiles.first(where: { $0.id == selected }) {
                    HStack { Text(profile.name).font(.headline); Spacer(); Button("编辑") { editing = profile }; Button("删除") { deleting = profile } }
                    textView(profile.content)
                    let issues = HostsSupport.issues(profile.content)
                    if !issues.isEmpty { issueView(issues) }
                } else {
                    Text("组合预览").font(.headline)
                    textView(service.candidate.isEmpty ? "# 暂未选择配置" : service.candidate)
                }
                if !service.issues.isEmpty { issueView(service.issues) }
                if selected != nil { Button("查看组合预览") { selected = nil } }
            }.padding(12).frame(minWidth: 440)
        }
    }
    private var history: some View {
        VStack(alignment: .leading) {
            Text("保留最近 30 份应用前备份。恢复只替换管理区块，完整原文件可复制用于手动检查。").foregroundStyle(.secondary)
            List(service.backups) { backup in
                HStack {
                    VStack(alignment: .leading) {
                        Text(backup.date.formatted(date: .abbreviated, time: .standard))
                        Text(backup.managedContent.isEmpty ? "未启用映射" : "\(HostsSupport.records(backup.managedContent).count) 条映射").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("复制原文件") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(backup.systemContent, forType: .string) }
                    Button("恢复管理区块") { restoring = backup }.disabled(!service.hasSnapshot)
                }.padding(.vertical, 4)
            }
        }.padding(12)
    }
    private func textView(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func issueView(_ issues: [HostsIssue]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) { ForEach(issues) { Text($0.message).foregroundStyle(.red).font(.caption).textSelection(.enabled) } }
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 100)
    }
}

private struct HostsProfileEditor: View {
    @ObservedObject var service: HostsService
    @State var profile: HostsProfile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑本地 Hosts 配置").font(.title2.bold())
            TextField("配置名称", text: $profile.name)
            TextEditor(text: $profile.content).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.3))
            let issues = HostsSupport.issues(profile.content)
            if !issues.isEmpty { Text(issues.first!.message).font(.caption).foregroundStyle(.red) }
            Text("格式：IP 地址 域名 [其他域名]；# 为注释。保存草稿不会立即修改系统 Hosts。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { if service.update(profile) { dismiss() } }.buttonStyle(.borderedProminent).disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.content.utf8.count > HostsSupport.limit) }
        }.padding(20).frame(width: 640, height: 460)
    }
}
