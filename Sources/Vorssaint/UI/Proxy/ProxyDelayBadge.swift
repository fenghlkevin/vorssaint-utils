// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ProxyDelayBadge: View {
    var delay: Int?
    var testing = false
    var queued = false
    var date: Date?
    var blocked = false
    private var text: String {
        if blocked { return "拦截" }
        if testing { return "测试中…" }
        if queued { return "等待中" }
        guard let delay else { return "未测试" }
        return delay > 0 ? "\(delay) ms" : "超时 / 失败"
    }
    private var color: Color {
        if blocked || testing || queued || delay == nil { return .secondary }
        guard let delay, delay > 0 else { return .red }
        return delay < 300 ? .green : .orange
    }
    var body: some View {
        Text(text).font(.caption.monospacedDigit()).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .help(date.map { "最近测试：" + $0.formatted(date: .omitted, time: .standard) + "；仅代表测试目标的连通性" } ?? "点击测试延迟检查连通性")
            .accessibilityLabel("连接测试：" + text)
    }
}
