// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

struct PanelProxyView: View {
    @ObservedObject var service: ProxyService = .shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(service.state == .running ? Color.green : Color.secondary).frame(width: 9, height: 9)
                Label { Text("网络代理 · \(service.stateText)") } icon: { ProxyBrandIcon() }
                Spacer()
                Button("工作台") { ProxyWindowController.shared.show() }
            }
            Text(service.selectedProfile?.name ?? "尚未导入本地配置").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(service.state != .stopped ? "停止" : "启动") {
                    if service.state != .stopped { service.stop() } else { service.start() }
                }.disabled(service.state == .stopped && !service.canStart)

            }
            if service.state == .running {
                Text(service.tunnelEffective ? "增强模式已接管" : service.systemProxyEffective ? "系统代理已开启" : "核心已运行 · 系统代理未开启")
                    .font(.caption).foregroundStyle(service.systemProxyEffective || service.tunnelEffective ? Color.green : Color.orange)
            }
            ProxyActiveClientsView(telemetry: service.telemetry)
            Divider()
            ProxyMenuContents(service: service)
            if let error = service.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }.onAppear { service.refreshTunnelAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in service.refreshTunnelAccess() }
        .padding(12).background(ProxyVisibilityProbe(telemetry: service.telemetry).frame(width: 0, height: 0))
    }
}

struct ProxyMenuContents: View {
    @ObservedObject var service: ProxyService
    var body: some View {
        HStack {
            Button("仪表盘") { ProxyWindowController.shared.show() }
            Button("连接") { ProxyWindowController.shared.show(page: 8) }
            Button("日志") { ProxyWindowController.shared.show(page: 9) }
            Button("诊断") { ProxyWindowController.shared.show(page: 10) }
        }
        Picker("出站模式", selection: Binding(get: { service.preferences.mode }, set: service.setMode)) {
            Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
        }.pickerStyle(.segmented).disabled(service.busy)
        Divider()
        ForEach(service.groups) { group in
            DisclosureGroup {
                Button("测试延迟") { service.test(group.members) }
                    .disabled(service.state != .running || !service.testingNodes.isEmpty)
                ForEach(group.members, id: \.self) { member in
                    Button { service.choose(group: group.name, member: member) } label: {
                        HStack {
                            Image(systemName: group.selected == member ? "checkmark" : "circle").frame(width: 16)
                            Text(member).lineLimit(1)
                            Spacer()
                            ProxyDelayBadge(delay: service.delays[member], testing: service.testingNodes.contains(member), date: service.delayDates[member], blocked: ["REJECT", "REJECT-DROP"].contains(member))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 4)
                        .disabled(service.state != .running || service.busy)
                }
            } label: {
                HStack {
                    Text(group.name).fontWeight(.medium)
                    Spacer()
                    Text(group.selected).foregroundStyle(.secondary).lineLimit(1)
                    ProxyDelayBadge(delay: service.delays[group.selected], testing: service.testingNodes.contains(group.selected), date: service.delayDates[group.selected], blocked: ["REJECT", "REJECT-DROP"].contains(group.selected))
                }
            }
        }
        Divider()
        if service.tunnelAccess != "已授权" {
            HStack {
                Button("授权网络助手") { service.authorizeTunnel() }
                    .disabled(service.state != .stopped || service.busy)
                Text(service.tunnelAccess).font(.caption).foregroundStyle(.secondary)
            }
            Text("系统代理和增强模式需要先授权网络助手。移除助手会关闭这两项；仅启动核心无需授权。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("设置为系统代理", isOn: Binding(get: { service.state == .running ? service.systemProxyEffective : service.preferences.systemProxy }, set: service.setSystemProxy))
        Toggle("增强模式 / TUN", isOn: Binding(get: { service.state == .running ? service.tunnelEffective : service.preferences.tunnelSettings.enabled }, set: service.setTunnel)).disabled(service.busy)
        Toggle("允许局域网访问", isOn: Binding(get: { service.preferences.allowLAN }, set: service.setLAN))
        Button("复制 Shell 代理命令") { service.copyShell() }
        Button("复制取消代理命令") { service.copyUnset() }
        Menu("使用局域网 IP 复制 Shell 命令") {
            ForEach((try? NetworkInfoLocalAddresses.read())?.filter { !$0.isTunnel } ?? []) { address in
                Button("\(address.interface) · \(address.ip)") { service.copyShell(host: address.ip) }
            }
        }.disabled(!service.preferences.allowLAN)
        Toggle("自动启动代理", isOn: Binding(get: { service.preferences.autoStart }, set: service.setAutoStart))
        Text("退出 Vorssaint 后代理继续运行；断开连接请点击停止代理。").font(.caption).foregroundStyle(.secondary)
        Divider()
        Menu("切换配置") {
            ForEach(service.profiles) { profile in
                Button((profile.id == service.selectedID ? "✓ " : "") + profile.name) { service.selectProfile(profile.id) }
            }
        }.disabled(service.busy)
        HStack {
            Button("重新加载配置") { service.reloadProfile() }.disabled(service.busy || service.selectedID == nil)
            Button("更新全部规则集") { service.refreshResources(update: "*") }.disabled(service.busy || service.state != .running)
        }
    }
}


struct ProxyNavigationIcon: View {
    @ObservedObject private var service = ProxyService.shared
    var body: some View {
        ProxyBrandIcon(size: 23)
            .overlay(alignment: .bottomTrailing) {
                if service.state == .running {
                    Circle().fill(.green).frame(width: 6, height: 6).offset(x: 4, y: 2)
                }
            }.accessibilityLabel("网络代理，" + service.stateText)
    }
}
