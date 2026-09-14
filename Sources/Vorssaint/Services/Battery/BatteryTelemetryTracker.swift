// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Describes observations, never infers unobserved power flow between samples.
struct BatteryTelemetryTracker {
    private var previous: (date: Date, percent: Int?, state: String)?

    mutating func observe(at date: Date, percent: Int?, external: Bool,
                          charging: Bool, watts: Double?) -> String {
        let flow: String
        if let watts, watts.isFinite {
            flow = watts < 0 ? (watts > -0.5 ? "微小放电读数" : "放电读数")
                : watts > 0 ? "充电读数" : "零电流读数"
        } else { flow = "电池功率未知" }
        let state = "接电=\(external) 系统充电标志=\(charging) \(flow)"
        var details = [state]
        if let previous {
            let seconds = date.timeIntervalSince(previous.date)
            if seconds > 90 { details.append("采样间隔\(Int(seconds))秒；期间供电过程未知") }
            if previous.state != state { details.append("状态变化：\(previous.state) → \(state)") }
            if let percent, let old = previous.percent, percent != old {
                details.append("电量变化\(old)%→\(percent)%（\(Int(max(0, seconds)))秒）；非连续功率测量")
            }
        } else { details.append("本轮采样基线；不推断此前状态") }
        previous = (date, percent, state)
        return details.joined(separator: "；")
    }
}
