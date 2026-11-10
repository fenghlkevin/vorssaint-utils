// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NetworkChainView: View {
    @StateObject private var chain = NetworkChainService()
    @ObservedObject private var traffic = AppTrafficService.shared
    @ObservedObject private var proxy = ProxyService.shared.telemetry
    @State private var selection: String?
    @State private var selectedSocket: String?
    @State private var showAllConnections = false
    @State private var sort = "total"
    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(max(0, value), Double(Int64.max / 2))), countStyle: .binary)
    }
    private func score(_ entry: AppTrafficEntry) -> Double {
        switch sort {
        case "speed": let rate = traffic.rates[entry.id]; return (rate?.down ?? 0) + (rate?.up ?? 0)
        case "down": return entry.downloaded
        case "up": return entry.uploaded
        default: return entry.total
        }
    }
    private var entries: [AppTrafficEntry] {
        var all = traffic.ledger.entries
        for process in chain.processes.values where all[process.id] == nil {
            all[process.id] = .init(id: process.id, name: process.name, appPath: process.path)
        }
        return all.values.sorted { score($0) == score($1) ? $0.id < $1.id : score($0) > score($1) }
    }
    private var selected: AppTrafficEntry? { entries.first { $0.id == selection } ?? entries.first }
    private var proxyRows: [ProxyConnection] {
        guard let selected, let path = selected.appPath, let date = proxy.sampleDate,
              Date().timeIntervalSince(date) < 10 else { return [] }
        return proxy.connections.filter { NetworkChainSupport.appPath(fromProcessPath: $0.processKey) == path }
            .sorted { $0.upload + $0.download > $1.upload + $1.download }
    }
    private func proxyTarget(_ socket: NetworkChainSocket) -> ProxyConnection? {
        guard let date = proxy.sampleDate, Date().timeIntervalSince(date) < 10,
              socket.remote.hasSuffix(":\(ProxyService.shared.preferences.mixedPort)"), socket.isLoopback else { return nil }
        let matches = proxy.connections.filter { row in
            NetworkFlowSupport.matchesSource(local: socket.local, remote: socket.remote, sourceIP: row.sourceIP,
                                             sourcePort: row.sourcePort, proxyPort: ProxyService.shared.preferences.mixedPort)
                && row.network.lowercased() == "tcp"
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private func flowTotal(_ socket: NetworkChainSocket) -> Double {
        if let target = proxyTarget(socket) { return target.download + target.upload }
        return chain.flows[socket.id]?.total ?? -1
    }
    private func targetName(_ socket: NetworkChainSocket) -> String {
        if let target = proxyTarget(socket) { return target.host.isEmpty ? target.destination : target.host }
        return socket.remote
    }
    private func routeName(_ socket: NetworkChainSocket, entry: AppTrafficEntry) -> String {
        if let peer = NetworkChainSupport.peer(of: socket, in: chain.sockets) {
            let peerName = chain.processes[peer.pid]?.name ?? peer.process
            if NetworkChainSupport.incoming(socket, in: chain.sockets) { return "\(peerName) → \(entry.name)（入站）" }
            if let target = proxyTarget(socket) { return "\(entry.name) → \(peerName) → \(target.host.isEmpty ? target.destination : target.host)" }
            return "\(entry.name) → \(peerName) → 下游待关联"
        }
        return "\(entry.name) → \(socket.isLoopback ? "本机进程未识别" : socket.remote)"
    }
    private func counterText(_ socket: NetworkChainSocket) -> String {
        if let target = proxyTarget(socket) { return "↓\(bytes(target.download))  ↑\(bytes(target.upload))" }
        guard let flow = chain.flows[socket.id] else { return "未采集" }
        return "↓\(bytes(flow.downloaded))  ↑\(bytes(flow.uploaded))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("软件流量与网络链路").font(.title2.bold())
                    Text("查看软件连接到哪里，区分本机通信与代理中转").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { chain.refresh() } label: { Label("刷新连接", systemImage: "arrow.clockwise") }.disabled(chain.loading)
            }
            HStack(spacing: 28) {
                Text("已记录 \(traffic.ledger.entries.count) 个软件")
                Text("TCP 端点 \(chain.sockets.filter { $0.state == "ESTABLISHED" }.count)")
                Text("开始 \(traffic.ledger.startedAt.formatted(date: .omitted, time: .shortened))")
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("排序", selection: $sort) {
                        Text("累计合计").tag("total"); Text("累计下载").tag("down")
                        Text("累计上传").tag("up"); Text("当前速度").tag("speed")
                    }.labelsHidden()
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(entries) { entry in
                                Button { selection = entry.id; selectedSocket = nil; showAllConnections = false } label: {
                                    appRow(entry)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(12).frame(width: 225)
                Divider()
                ScrollView {
                    if let selected { detail(selected).id(selected.id).padding(20) }
                    else { Text(chain.loading ? "正在读取本机连接…" : "暂未记录软件网络活动").foregroundStyle(.secondary).padding(30) }
                }.frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Label(traffic.status == "recording" ? "后台流量统计中" : "流量采集等待恢复", systemImage: "circle.fill")
                    .foregroundStyle(traffic.status == "recording" ? .green : .orange)
                if let date = chain.sampledAt { Text("连接快照 \(date.formatted(date: .omitted, time: .standard)) · 每 5 秒刷新") }
                Spacer()
            }.font(.caption)
            if let issue = chain.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if let issue = chain.flowIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            Text("累计含本机通信与代理中转，各软件不可相加作为整机互联网流量。当前路径仅展示 TCP 快照；短连接、UDP 或权限受限进程可能缺失。\(traffic.ledger.interrupted ? "记录曾中断。" : "")\(traffic.saveFailed ? "本机累计保存失败。" : "")")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { chain.start() }.onDisappear { chain.stop() }
    }
    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
        }
    }
    private func appRow(_ entry: AppTrafficEntry) -> some View {
        HStack(spacing: 8) {
            if let path = entry.appPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 26, height: 26)
            } else { Image(systemName: "gearshape").frame(width: 26) }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(bytes(entry.total)) · \(chain.sockets.filter { $0.state == "ESTABLISHED" && chain.processes[$0.pid]?.id == entry.id }.count) 个端点")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(10).background(selected?.id == entry.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
    private func detail(_ entry: AppTrafficEntry) -> some View {
        let currentConnections = chain.sockets.filter { $0.state == "ESTABLISHED" && chain.processes[$0.pid]?.id == entry.id }.sorted { flowTotal($0) == flowTotal($1) ? $0.id < $1.id : flowTotal($0) > flowTotal($1) }
        let currentSocket = currentConnections.first { $0.id == selectedSocket } ?? currentConnections.first
        return VStack(alignment: .leading, spacing: 12) {
            Text(entry.name).font(.title3.bold())
            HStack(spacing: 30) {
                summary("累计下载", bytes(entry.downloaded)); summary("累计上传", bytes(entry.uploaded))
                let rate = traffic.rates[entry.id]
                summary("当前速度", "↓\(MetricFormat.bytesPerSecCompact(rate?.down ?? 0)) ↑\(MetricFormat.bytesPerSecCompact(rate?.up ?? 0))")
            }
            Divider()
            HStack {
                Text("当前连接路径").font(.headline)
                Spacer()
                if let socket = currentSocket { Text(counterText(socket)).font(.caption).monospacedDigit() }
            }
            if let socket = currentSocket {
                path(socket, entry: entry).id(socket.id)
                Text("本地端点 \(socket.local) · PID \(socket.pid) · \(socket.process)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).id(socket.id)
            } else {
                Text("当前没有可见 TCP 连接。已保存的累计流量仍保留，不代表软件从未联网。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !currentConnections.isEmpty {
                HStack {
                    Text("目标连接（\(currentConnections.count)）").font(.headline)
                    Spacer()
                    Text("按连接流量排序").font(.caption).foregroundStyle(.secondary)
                }
                Text("逐连接计量 · 含连接已有流量 · 连接关闭后移出本表")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("目标 / 路径"); Spacer(); Text("下载 / 上传 / 合计")
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(Array(currentConnections.prefix(showAllConnections ? currentConnections.count : 6))) { socket in
                    Button { selectedSocket = socket.id } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(targetName(socket)).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(routeName(socket, entry: entry)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("\(socket.local) · \(socket.process)").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(flowTotal(socket) >= 0 ? bytes(flowTotal(socket)) : "未采集").font(.system(size: 12, weight: .semibold))
                                Text(counterText(socket)).font(.caption).foregroundStyle(.secondary)
                                if let flow = chain.flows[socket.id], let down = flow.downloadRate, let up = flow.uploadRate {
                                    Text("↓\(MetricFormat.bytesPerSecCompact(down)) ↑\(MetricFormat.bytesPerSecCompact(up))")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(proxyTarget(socket) == nil ? "系统连接累计" : "代理目标累计").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }.monospacedDigit().frame(minWidth: 145, alignment: .trailing)
                        }.padding(10)
                            .background(currentSocket?.id == socket.id ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }
            if currentConnections.count > 6 {
                Button(showAllConnections ? "收起连接" : "查看全部 \(currentConnections.count) 条连接") { showAllConnections.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            Divider()
            Text("自有代理报告的目标").font(.headline)
            if proxyRows.isEmpty {
                Text("暂无可匹配的代理目标。只有自有代理提供了当前软件的进程路径时才展示；不会自动开启代理或修改 FlClash。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("按代理报告的进程路径匹配；以下为活动连接累计，不是开机总量，也未逐条关联上方 TCP 端点。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(proxyRows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(row.host.isEmpty ? row.destination : row.host); Spacer(); Text("↓\(bytes(row.download)) ↑\(bytes(row.upload))") }
                        Text(row.chains).foregroundStyle(.secondary)
                        Text(row.rule).foregroundStyle(.secondary)
                    }.font(.caption).textSelection(.enabled).padding(.vertical, 5)
                }
            }
            DisclosureGroup("累计子进程（\(entry.children.count)）") {
                ForEach(entry.children.sorted { $0.value > $1.value }, id: \.key) { child in
                    HStack { Text(child.key); Spacer(); Text(bytes(child.value)) }.font(.caption).padding(.vertical, 4)
                }
            }
        }
    }
    private func path(_ socket: NetworkChainSocket, entry: AppTrafficEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let peer = NetworkChainSupport.peer(of: socket, in: chain.sockets) {
                let peerName = chain.processes[peer.pid]?.name ?? peer.process
                let incoming = NetworkChainSupport.incoming(socket, in: chain.sockets)
                HStack(alignment: .top, spacing: 10) {
                    node(entry.name, subtitle: socket.local)
                    Image(systemName: incoming ? "arrow.left" : "arrow.right").padding(.top, 18)
                    node(peerName, subtitle: socket.remote)
                    if !incoming {
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 18)
                        if let target = proxyTarget(socket) {
                            node(target.host.isEmpty ? target.destination : target.host, subtitle: "代理目标 · 来源端口匹配")
                        } else {
                            node("下游待关联", subtitle: "目标域名 / 服务未知")
                        }
                    }
                }
                Label("已确认本机连接 · 反向端点匹配", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
                if let target = proxyTarget(socket) {
                    Label("已确认代理目标 · 来源端点匹配", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
                    Text("代理报告路径：\(target.chains)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("下游待关联：尚未取得此连接的代理目标记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    node(entry.name, subtitle: socket.local)
                    Image(systemName: "arrow.right").padding(.top, 18)
                    node(socket.remote, subtitle: socket.isLoopback ? "本机服务 · 进程未识别" : "网络端点 · TCP")
                }
                Text(socket.isLoopback ? "对端进程暂不可见，下游待关联" : "已发现网络连接；代理、隧道及请求关系未推断")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func node(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
