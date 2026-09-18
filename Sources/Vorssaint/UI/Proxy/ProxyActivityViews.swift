// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Charts
import AppKit

struct ProxyTrafficView: View {
    @ObservedObject var telemetry: ProxyTelemetry
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                metric("上传", telemetry.sampleDate == nil ? "—" : ProxyTelemetry.bytes(telemetry.uploadRate) + "/s")
                metric("下载", telemetry.sampleDate == nil ? "—" : ProxyTelemetry.bytes(telemetry.downloadRate) + "/s")
                metric("连接", telemetry.sampleDate == nil ? "—" : "\(telemetry.connectionCount)")
                metric("核心内存", telemetry.memory.map(ProxyTelemetry.bytes) ?? "—")
            }
            Chart(telemetry.history) { point in
                LineMark(x: .value("时间", point.date), y: .value("字节/秒", point.upload)).foregroundStyle(by: .value("方向", "上传"))
                LineMark(x: .value("时间", point.date), y: .value("字节/秒", point.download)).foregroundStyle(by: .value("方向", "下载"))
            }.chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let number = value.as(Double.self) { Text(ProxyTelemetry.bytes(number) + "/s") } } } }.frame(height: 100)
            Text("本次核心累计：↑ \(ProxyTelemetry.bytes(telemetry.uploadTotal))  ↓ \(ProxyTelemetry.bytes(telemetry.downloadTotal)) · 仅统计经过核心的流量")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = telemetry.issue { Text(issue).foregroundStyle(.orange) }
        }.padding(10)
    }
    private func metric(_ label: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.monospacedDigit()) } }
}

struct ProxyActiveClientsView: View {
    @ObservedObject var telemetry: ProxyTelemetry
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("活跃客户端").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<6, id: \.self) { index in
                    Group {
                        if index < telemetry.clients.count {
                            let client = telemetry.clients[index]
                            Button {
                                telemetry.processFilter = client.id; ProxyWindowController.shared.show(page: 8)
                            } label: {
                                HStack {
                                    Image(systemName: "app")
                                    Text(client.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("↑\(ProxyTelemetry.bytes(client.uploadRate)) ↓\(ProxyTelemetry.bytes(client.downloadRate))/s")
                                        .font(.caption.monospacedDigit()).lineLimit(1)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        } else if index == 0 {
                            Text(telemetry.sampleDate == nil ? "等待流量数据…" : "暂无活跃连接")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Color.clear.accessibilityHidden(true)
                        }
                    }.frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("查看全部连接") { telemetry.processFilter = nil; ProxyWindowController.shared.show(page: 8) }
        }
    }
}

struct ProxyConnectionsView: View {
    @ObservedObject var telemetry: ProxyTelemetry
    @State private var search = ""
    @State private var selection: String?
    @State private var confirmAll = false
    @State private var actionError: String?
    @State private var deleting = false
    private var rows: [ProxyConnection] {
        telemetry.connections.filter { row in
            (telemetry.processFilter == nil || row.processKey == telemetry.processFilter) &&
            (search.isEmpty || [row.process, row.host, row.destination, row.rule, row.chains].contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.id < $1.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("搜索进程、域名、IP、规则或策略链", text: $search)
                if telemetry.processFilter != nil { Button("清除应用筛选") { telemetry.processFilter = nil } }
                Button("断开选中") { if let selection { close(selection) } }.disabled(selection == nil || deleting || telemetry.sampleDate == nil)
                Button("断开全部…", role: .destructive) { confirmAll = true }.disabled(deleting || telemetry.connectionCount == 0 || telemetry.sampleDate == nil)
            }
            Text("\(rows.count) 条匹配 · 核心共 \(telemetry.connectionCount) 条；应用可能自动重连。进程未知时不猜测应用身份。").font(.caption).foregroundStyle(.secondary)
            if telemetry.connectionCount > 5000 { Text("当前仅展示前 5000 条连接，流量总计仍来自核心全量计数。").foregroundStyle(.orange) }
            if let error = actionError ?? telemetry.issue { Text(error).foregroundStyle(.red) }
            Table(rows, selection: $selection) {
                TableColumn("应用", value: \.process).width(min: 90, ideal: 130)
                TableColumn("目标") { row in Text(row.host.isEmpty ? row.destination : row.host).help(row.destination) }.width(min: 120, ideal: 190)
                TableColumn("协议", value: \.network).width(50)
                TableColumn("规则", value: \.rule).width(min: 70, ideal: 100)
                TableColumn("上传 / 下载") { row in Text("\(ProxyTelemetry.bytes(row.uploadRate)) / \(ProxyTelemetry.bytes(row.downloadRate))/s").monospacedDigit() }.width(min: 130, ideal: 150)
            }
            if let row = rows.first(where: { $0.id == selection }) {
                Text("\(row.processKey)\n\(row.destination) · \(row.chains)\n开始：\(row.started) · 累计 ↑\(ProxyTelemetry.bytes(row.upload)) ↓\(ProxyTelemetry.bytes(row.download))")
                    .font(.caption).textSelection(.enabled).lineLimit(4)
            }
        }.padding(12)
        .confirmationDialog("断开核心的全部连接？应用可能自动重连。", isPresented: $confirmAll) {
            Button("断开全部", role: .destructive) { close(nil) }
        }
    }
    private func close(_ id: String?) {
        deleting = true; actionError = nil
        Task { defer { deleting = false }; do { if let id { try await telemetry.closeConnection(id) } else { try await telemetry.closeAll() } } catch { actionError = error.localizedDescription } }
    }
}

struct ProxyLogsView: View {
    @ObservedObject var telemetry: ProxyTelemetry
    @State private var search = ""
    @State private var clear = false
    @State private var exportError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("采集级别", selection: $telemetry.logLevel) { Text("调试").tag("debug"); Text("信息").tag("info"); Text("警告").tag("warning"); Text("错误").tag("error") }.frame(width: 190)
                Spacer()
                Toggle("暂停", isOn: $telemetry.logsPaused).toggleStyle(.switch)
                Button("导出日志") { export() }
                Button("清空…") { clear = true }
            }
            TextField("搜索日志", text: $search)
            Text("默认采集警告，内存保留最近 1000 条，磁盘轮转约 1 MiB。凭据脱敏后保存；日志仍可能包含域名和 IP，请谨慎分享。采集级别同步到当前核心，不修改配置草稿。").font(.caption).foregroundStyle(.secondary)
            if telemetry.droppedLogCount > 0 { Text("高频日志超过写入队列容量，已丢弃 \(telemetry.droppedLogCount) 条最旧待写日志。").font(.caption).foregroundStyle(.orange) }
            if let issue = exportError ?? telemetry.logIssue { Text(issue).foregroundStyle(.orange) }
            List(telemetry.logs.filter { search.isEmpty || $0.message.localizedCaseInsensitiveContains(search) || $0.level.localizedCaseInsensitiveContains(search) }) { entry in
                HStack(alignment: .top) {
                    Text(entry.date, style: .time).frame(width: 75, alignment: .leading)
                    Text(entry.level).frame(width: 60, alignment: .leading).foregroundStyle(entry.level == "error" ? .red : .secondary)
                    Text(entry.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(.caption, design: .monospaced))
            }
        }.padding(12)
        .confirmationDialog("清除内存和磁盘日志？", isPresented: $clear) { Button("清除日志", role: .destructive) { telemetry.clearLogs() } }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "vorssaint-proxy-logs.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(telemetry.logs).write(to: url, options: .atomic); exportError = nil }
        catch { exportError = error.localizedDescription }
    }
}
