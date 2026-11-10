// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AppTrafficView: View {
    @ObservedObject private var traffic = AppTrafficService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage("network.traffic.sort") private var sort = "total"
    @State private var showingChains = false
    @State private var showAll = false
    private var chinese: Bool { l10n.language.rawValue.hasPrefix("zh") }
    private func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(max(0, value), Double(Int64.max / 2))), countStyle: .binary)
    }
    private func score(_ row: AppTrafficEntry) -> Double {
        switch sort {
        case "down": return row.downloaded
        case "up": return row.uploaded
        default: return row.total
        }
    }
    private var sorted: [AppTrafficEntry] {
        traffic.ledger.entries.values.sorted {
            let a = score($0), b = score($1)
            return a == b ? $0.id < $1.id : a > b
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(text("软件流量 · 本次开机记录", "App traffic · this boot"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker(text("排序", "Sort"), selection: $sort) {
                    Text(text("累计合计", "Total")).tag("total")
                    Text(text("累计下载", "Downloaded")).tag("down")
                    Text(text("累计上传", "Uploaded")).tag("up")
                }.labelsHidden().frame(width: 108).controlSize(.mini)
            }
            Button("查看网络链路") { showingChains = true }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            HStack(spacing: 4) {
                Circle().fill(traffic.status == "recording" ? Color.green : Color.orange).frame(width: 5, height: 5)
                Text(statusText).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(text("开机 ", "Boot ") + traffic.ledger.bootDate.formatted(date: .omitted, time: .shortened)
                 + text(" · 开始记录 ", " · Recording since ")
                 + traffic.ledger.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            if let date = traffic.ledger.includesLoopbackSince {
                Text(text("本机代理流量自 ", "Local proxy traffic included since ")
                     + date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if traffic.ledger.interrupted {
                Text(text("记录曾中断，累计仅包含已采集流量", "Recording has gaps; totals include observed traffic only"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if traffic.saveFailed {
                Text(text("本机记录保存失败，退出后可能丢失", "Could not save locally; totals may be lost on quit"))
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
            if sorted.isEmpty {
                Text(text("正在等待软件网络活动…", "Waiting for app network activity…"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(Array(sorted.prefix(showAll ? sorted.count : 6))) { row in
                DisclosureGroup {
                    ForEach(row.children.sorted { $0.value > $1.value }, id: \.key) { child in
                        HStack {
                            Text(child.key).lineLimit(1)
                            Spacer()
                            Text(bytes(child.value))
                        }.font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let path = row.appPath {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "gearshape").frame(width: 14)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.system(size: 10.5)).lineLimit(1)
                            Text("↓\(bytes(row.downloaded))  ↑\(bytes(row.uploaded))")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(bytes(row.total)).font(.system(size: 10.5, weight: .medium))
                        }.monospacedDigit()
                    }
                }.help(row.appPath ?? row.name)
            }
            if sorted.count > 6 {
                Button(showAll ? text("收起", "Show less") : text("查看全部 \(sorted.count) 项", "Show all \(sorted.count)")) {
                    showAll.toggle()
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.accentColor)
            }
            Text(text("累计上传与下载 · 包含本机代理连接；代理自身也会计数，勿相加作为整机流量。ChatGPT / Codex 为共享应用合计，可展开查看子进程。", "Cumulative upload and download · includes local proxy connections. Proxies also count traffic; do not sum app rows as device totals. ChatGPT / Codex shares one app total; expand for processes."))
                .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingChains) {
            VStack {
                HStack { Spacer(); Button("关闭") { showingChains = false }.keyboardShortcut(.cancelAction) }
                NetworkChainView()
            }.padding(24).frame(width: 940, height: 720)
        }
    }
    private var statusText: String {
        switch traffic.status {
        case "recording": return text("后台统计中", "Recording in background")
        case "failed": return text("采集失败，15 秒后自动重试", "Collection failed; retrying in 15 seconds")
        case "waiting": return text("等待采集恢复，当前速度已清零", "Waiting for collection; current speeds cleared")
        default: return text("正在启动采集…", "Starting collection…")
        }
    }
}
