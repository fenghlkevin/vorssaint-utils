// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

struct PanelProxyView: View {
    @ObservedObject var service: ProxyService = .shared
    @State private var showingNodes = false
    @State private var pendingSelection: (group: String, member: String)?

    // Follow the selected group chain instead of assuming a profile has a group named “manual”.
    private var currentGroup: ProxyGroup? {
        var group = service.groups.first { $0.name == (service.preferences.mode == "global" ? "GLOBAL" : "Proxy") }
            ?? service.groups.first
        var visited = Set<String>()
        while let current = group, visited.insert(current.name).inserted,
              let next = service.groups.first(where: { $0.name == current.selected }),
              !visited.contains(next.name) {
            group = next
        }
        return group
    }

    private var statusSummary: String {
        guard service.state == .running else {
            return service.statusDetail.isEmpty ? "打开代理后按当前配置连接" : service.statusDetail
        }
        return "系统代理" + (service.systemProxyEffective ? "已开启" : "未开启")
            + " · TUN " + (service.tunnelEffective ? "已开启" : "未开启")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("网络代理").font(.system(size: 18, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(service.state == .running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(service.stateText).font(.caption).foregroundStyle(.secondary)
                        if service.busy { ProgressView().controlSize(.mini) }
                    }
                }
                Spacer()
                Button(service.state == .stopped ? "连接" : service.state == .running ? "断开" : "停止") {
                    if service.state == .stopped { service.start() } else { service.stop() }
                }
                .disabled(service.state == .stopped ? !service.canStart : service.state == .stopping)
                .controlSize(.large)
            }
            Text(statusSummary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            nodePicker

            if !showingNodes {
                VStack(alignment: .leading, spacing: 6) {
                    Text("分流模式").font(.caption).foregroundStyle(.secondary)
                    Picker("分流模式", selection: Binding(get: { service.preferences.mode }, set: service.setMode)) {
                        Text("规则").tag("rule")
                        Text("全局").tag("global")
                        Text("直连").tag("direct")
                    }.pickerStyle(.segmented).labelsHidden().disabled(service.busy)
                }
                VStack(spacing: 10) {
                    switchRow("系统代理", isOn: Binding(get: {
                        service.state == .running ? service.systemProxyEffective : service.preferences.systemProxy
                    }, set: service.setSystemProxy)).disabled(service.busy)
                    Divider()
                    switchRow("增强模式 / TUN", isOn: Binding(get: {
                        service.preferences.tunnelSettings.enabled || service.tunnelEffective
                    }, set: service.setTunnel))
                    .disabled(service.busy && !service.preferences.tunnelSettings.enabled && !service.tunnelEffective)
                    Divider()
                    switchRow("自动启动代理", isOn: Binding(get: { service.preferences.autoStart }, set: service.setAutoStart))
                        .help("Vorssaint 打开时自动启动代理；开机启动应用请在应用设置中开启。")
                }
                .toggleStyle(.switch).controlSize(.small)
                .padding(12).background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))

            }
            if service.preferences.tunnelSettings.enabled || service.tunnelEffective {
                Button("关闭 TUN 并停止代理") { service.disableTunnelAndStop() }
                    .font(.caption).foregroundStyle(.orange)
            }
            if service.tunnelAccess != "已授权" {
                Button { ProxyWindowController.shared.show(page: 6) } label: {
                    Label("网络助手\(service.tunnelAccess) · 前往授权", systemImage: "info.circle")
                        .font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            if !showingNodes {
                ProxyMenuTraffic(telemetry: service.telemetry, running: service.state == .running)
                Divider()
                Menu {
                    ForEach(service.profiles) { profile in
                        Button((profile.id == service.selectedID ? "✓ " : "") + profile.name) { service.selectProfile(profile.id) }
                    }
                    Divider()
                    Button("管理配置…") { ProxyWindowController.shared.show(page: 2) }
                } label: {
                    Text("配置 · " + (service.selectedProfile?.name ?? "导入配置…"))
                        .lineLimit(1).truncationMode(.middle)
                }.menuStyle(.borderlessButton).disabled(service.busy)
            }
            if let error = service.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .onAppear { service.refreshTunnelAccess() }
        .onChange(of: service.busy) { _, busy in
            guard !busy, let pending = pendingSelection else { return }
            pendingSelection = nil
            if service.error == nil,
               service.groups.contains(where: { $0.name == pending.group && $0.selected == pending.member }) {
                showingNodes = false
            }
        }
        .onChange(of: service.selectedID) { _, _ in showingNodes = false; pendingSelection = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in service.refreshTunnelAccess() }
        .background(ProxyVisibilityProbe(telemetry: service.telemetry).frame(width: 0, height: 0))
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }

    private var nodeChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let group = currentGroup {
                HStack {
                    Text("策略组 " + group.name).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(service.testingNodes.isEmpty ? "测试全部" : service.delayTestProgress) { service.test(group.members) }
                        .disabled(service.state != .running || !service.testingNodes.isEmpty || service.busy)
                        .controlSize(.small)
                }
                VStack(spacing: 2) {
                    ForEach(group.members, id: \.self) { member in
                        Button {
                            if member == group.selected { showingNodes = false }
                            else {
                                pendingSelection = (group.name, member)
                                service.choose(group: group.name, member: member)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: member == group.selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(member == group.selected ? Color.accentColor : Color.secondary)
                                Text(member).lineLimit(2).help(member)
                                Spacer(minLength: 8)
                                ProxyDelayBadge(delay: service.delays[member],
                                                testing: service.activeTestingNodes.contains(member), queued: service.testingNodes.contains(member) && !service.activeTestingNodes.contains(member),
                                                date: service.delayDates[member],
                                                blocked: ["REJECT", "REJECT-DROP"].contains(member))
                                    .fixedSize()
                            }
                            .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(service.state != .running || service.busy)
                    }
                }
                Divider()
            }
            Button("全部策略组…") { ProxyWindowController.shared.show(page: 1) }
        }.padding(.horizontal, 13).padding(.bottom, 13)
    }

    private var nodePicker: some View {
        VStack(spacing: 0) {
        Button { showingNodes.toggle() } label: {
            VStack(alignment: .leading, spacing: 7) {
                Text(service.preferences.mode == "direct" ? "当前出站" : "当前节点 / 策略").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(service.preferences.mode == "direct" ? "DIRECT" : currentGroup?.selected ?? "尚未选择")
                        .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if service.preferences.mode != "direct", let group = currentGroup {
                        ProxyDelayBadge(delay: service.delays[group.selected], testing: service.activeTestingNodes.contains(group.selected), queued: service.testingNodes.contains(group.selected) && !service.activeTestingNodes.contains(group.selected), date: service.delayDates[group.selected], blocked: ["REJECT", "REJECT-DROP"].contains(group.selected))
                    }
                    Label(showingNodes ? "收起" : "展开", systemImage: showingNodes ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(service.preferences.mode == "direct" ? "所有流量直连" : currentGroup.map { "策略组 " + $0.name } ?? "打开工作台管理节点")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
        .accessibilityValue(showingNodes ? "已展开" : "已折叠")
        if showingNodes { nodeChoices }
        }.background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProxyMenuTraffic: View {
    @ObservedObject var telemetry: ProxyTelemetry
    let running: Bool
    @State private var expanded = false

    private var connectionSummary: String {
        guard running else { return "未连接" }
        return telemetry.sampleDate == nil ? "等待数据…" : "\(telemetry.connectionCount) 个活跃"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text("连接与流量")
                    Spacer()
                    Text(connectionSummary).foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.vertical, 4)
            }.buttonStyle(.plain)
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .accessibilityHint("点击展开或收起流量详情")

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 22) {
                        metric("下载", systemImage: "arrow.down", rate: telemetry.downloadRate)
                        metric("上传", systemImage: "arrow.up", rate: telemetry.uploadRate)
                    }
                    Divider()
                    total("本次累计下载", value: telemetry.downloadTotal)
                    total("本次累计上传", value: telemetry.uploadTotal)
                    Button {
                        telemetry.processFilter = nil
                        ProxyWindowController.shared.show(page: 8)
                    } label: {
                        HStack {
                            Text("查看全部连接")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                .padding(12)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func total(_ title: String, value: Double) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(!running || telemetry.sampleDate == nil ? "—" : ProxyTelemetry.bytes(value)).monospacedDigit()
        }.font(.caption)
    }

    private func metric(_ title: String, systemImage: String, rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
            Text(!running ? "0 B/s" : telemetry.sampleDate == nil ? "—" : ProxyTelemetry.bytes(rate) + "/s")
                .font(.system(size: 18, weight: .medium).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
