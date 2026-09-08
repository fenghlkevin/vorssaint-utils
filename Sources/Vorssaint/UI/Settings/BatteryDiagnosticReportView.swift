// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Deliberately does not observe the live service: log arrivals cannot relayout this sheet.
struct BatteryDiagnosticReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State var snapshot: BatteryDiagnosticSnapshot
    @State private var confirmClear = false
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("电池后台诊断报告").font(.title2)
            Text("生成于 \(snapshot.generatedAt.formatted(date: .abbreviated, time: .standard)) · 固定快照")
                .font(.caption).foregroundStyle(.secondary)
            Text("显示最近 \(snapshot.recentEvents.count) / \(snapshot.events.count) 条日志；后台新日志不会自动刷新此报告。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(snapshot.summary).textSelection(.enabled)
                    Divider()
                    if snapshot.events.isEmpty { Text("暂无日志") }
                    ForEach(Array(snapshot.recentEvents.enumerated()), id: \.offset) { _, entry in
                        Text(entry).textSelection(.enabled)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }.id(snapshot.id)
            Text(feedback).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("刷新快照") {
                    snapshot = BatteryManagementService.shared.makeDiagnosticSnapshot()
                    feedback = "已读取当前记录，未发起后台检查。"
                }
                Button("复制完整报告") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snapshot.report, forType: .string)
                    feedback = "已复制此快照的完整报告，共 \(snapshot.events.count) 条日志。"
                }
                Button("清空日志…", role: .destructive) { confirmClear = true }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 700, height: 520)
        .confirmationDialog("清空电池诊断日志？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                BatteryManagementService.shared.clearDiagnosticEvents()
                snapshot = BatteryManagementService.shared.makeDiagnosticSnapshot()
                feedback = "已清空 App 保存的日志，无法撤销；后续事件仍会正常记录。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除 App 内存及本地保存的历史日志，不影响充电设置、后台恢复记录或 macOS 系统日志。此操作无法撤销。")
        }
    }
}
