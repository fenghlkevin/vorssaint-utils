// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ProxyNetworkView: View {
    @ObservedObject var service: ProxyService
    @State private var exclusions = ""
    @State private var dnsServer = ""
    @State private var domain = ""
    @State private var targetPort = 443
    var body: some View {
        Form {
            Section("增强模式 / TUN") {
                LabeledContent("网络助手", value: service.tunnelAccess)
                HStack { Button("授权 / 打开系统批准") { service.authorizeTunnel() }; Button("刷新授权状态") { service.refreshTunnelAccess() }; Button("移除助手") { service.removeTunnelHelper() }.disabled(service.state != .stopped) }
                Toggle("启用增强模式", isOn: Binding(get: { service.state == .running ? service.tunnelEffective : service.preferences.tunnelSettings.enabled }, set: service.setTunnel))
                LabeledContent("实际状态", value: service.tunnelStatus)
                Text("只由助手创建网卡并管理自有路由；核心以当前用户运行。默认保留系统 DNS，不劫持端口 53。VPN 全隧道、无法可靠绑定的 VPN 分流路由或出口变化时暂停增强模式。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("同时接管 IPv6", isOn: Binding(get: { service.preferences.tunnelSettings.ipv6 }, set: { value in var next = service.preferences; next.tunnelSettings.ipv6 = value; service.savePreferences(next) })).disabled(service.state != .stopped)
                Text("关闭 IPv6 接管时，IPv6 继续使用系统路由；这不等同于禁用 IPv6。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("额外排除网段 / 已确认的 VPN 服务器 IP（每行一个 CIDR）")
                TextEditor(text: $exclusions).font(.system(.callout, design: .monospaced)).frame(height: 85).disabled(service.state != .stopped)
                HStack {
                    Button("保存排除项") { var next = service.preferences; next.tunnelSettings.exclusions = exclusions.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; service.savePreferences(next) }.disabled(service.state != .stopped)
                    Button("预检路由（不修改网络）") { service.previewTunnel() }
                }
                if !service.tunnelPreview.isEmpty { Text(service.tunnelPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }.disabled(service.busy)
            Section("公司网络检测") {
                TextField("公司 DNS IP", text: $dnsServer)
                TextField("公司域名", text: $domain)
                TextField("目标 TCP 端口", value: $targetPort, format: .number.grouping(.never))
                Button("检测 DNS → 解析 → 路由 → 服务") { service.diagnoseCompany(server: dnsServer, domain: domain, port: targetPort) }.disabled(service.busy || dnsServer.isEmpty || domain.isEmpty)
                Text("仅在点击时检测；直接查询指定公司 DNS，不向公网 DNS 回退。接口名不被用来猜测 VPN 产品。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(service.networkChecks) { check in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(check.title, systemImage: check.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(check.succeeded ? .green : .orange)
                        Text(check.detail).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }.formStyle(.grouped).onAppear { service.refreshTunnelAccess(); exclusions = service.preferences.tunnelSettings.exclusions.joined(separator: "\n"); dnsServer = service.companyDefaults.server; domain = service.companyDefaults.domain }
    }
}
