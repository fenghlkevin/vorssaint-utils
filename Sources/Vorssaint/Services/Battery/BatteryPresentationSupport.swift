// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum BatteryMenuField: String, CaseIterable, Identifiable {
    case source, cycles, temperature, health, lastDischarge, lastFullCharge, history, power, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: return "电源来源"
        case .cycles: return "电池循环次数"
        case .temperature: return "电池温度"
        case .health: return "电池健康"
        case .lastDischarge: return "上次放电时间"
        case .lastFullCharge: return "上次完全充电时间"
        case .history: return "12 小时电量曲线"
        case .power: return "功率分配"
        case .apps: return "高能耗应用"
        }
    }
    func isVisible(hidden: String) -> Bool { !hidden.split(separator: ",").contains(Substring(rawValue)) }
    func settingVisible(_ visible: Bool, hidden: String) -> String {
        var fields = Set(hidden.split(separator: ",").map(String.init))
        if visible { fields.remove(rawValue) } else { fields.insert(rawValue) }
        return fields.sorted().joined(separator: ",")
    }
}

/// One low-battery alert per discharge episode; invalid data never rearms it.
struct BatteryLowAlertPolicy {
    private(set) var sent = false
    mutating func shouldNotify(percent: Int?, discharging: Bool, enabled: Bool, threshold: Int) -> Bool {
        guard enabled else { sent = false; return false }
        guard let percent, (0...100).contains(percent) else { return false }
        let limit = min(30, max(5, threshold))
        if !discharging || percent >= limit + 5 { sent = false; return false }
        guard percent <= limit, !sent else { return false }
        sent = true
        return true
    }
}
