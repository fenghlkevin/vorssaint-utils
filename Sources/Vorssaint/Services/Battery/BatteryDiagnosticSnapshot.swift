// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct BatteryDiagnosticSnapshot: Identifiable {
    let id = UUID()
    let generatedAt: Date
    let summary: String
    let events: [String]
    var recentEvents: [String] { Array(events.prefix(50)) }
    var report: String {
        "报告生成时间：\(generatedAt.ISO8601Format())\n\(summary)\n\n" + events.joined(separator: "\n")
    }
}
