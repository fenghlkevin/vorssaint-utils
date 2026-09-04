// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Direction comes from measured battery current, not the requested charge mode.
struct BatteryPowerFlow {
    struct Node: Identifiable {
        enum Kind: String { case adapter, battery, computer }
        let kind: Kind
        let watts: Double?
        var id: String { kind.rawValue }
        var title: String {
            switch kind { case .adapter: return "电源"; case .battery: return "电池"; case .computer: return "电脑" }
        }
        var symbol: String {
            switch kind { case .adapter: return "bolt.fill"; case .battery: return "battery.100percent"; case .computer: return "laptopcomputer" }
        }
    }
    let inputs: [Node]
    let outputs: [Node]
    let note: String?

    init(external: Bool, hasBattery: Bool, charging: Bool,
         adapter: Double?, battery: Double?, system: Double?, forcedDischarge: Bool = false) {
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, abs(value) < 1000 else { return nil }
            return value
        }
        let a = valid(adapter).flatMap { $0 >= 0 ? $0 : nil }
        let b = hasBattery ? valid(battery) : nil
        let measuredSystem = valid(system).flatMap { $0 >= 0 ? $0 : nil }
        // Ignore sub-0.5 W noise, but show a charge destination when macOS
        // explicitly reports charging even while a current reading is missing.
        let discharging = (b ?? 0) < -0.5 || forcedDischarge
        let batterySource = b.flatMap { $0 < -0.5 ? -$0 : nil } ?? (forcedDischarge ? measuredSystem : nil)
        let filling = !discharging && ((b ?? 0) > 0.5 || charging)
        let usingAdapter = external || !hasBattery
        var sources: [Node] = []
        if usingAdapter { sources.append(Node(kind: .adapter, watts: a)) }
        if hasBattery && (!usingAdapter || discharging) {
            sources.append(Node(kind: .battery, watts: batterySource))
        }
        // Build a balanced flow from its boundary measurements. PSTR and PDTR
        // are independent rails and can be sampled at different instants; using
        // PSTR beside PDTR can visibly create energy. Keep PSTR only as fallback.
        let computer: Double? = {
            if usingAdapter, let a {
                if let b, b > 0.5 { return max(0, a - b) }
                if let b, b < -0.5 { return a + -b }
                return a
            }
            if hasBattery, let batterySource { return batterySource }
            return measuredSystem
        }()
        var sinks = [Node(kind: .computer, watts: computer)]
        if usingAdapter && hasBattery && filling {
            sinks.append(Node(kind: .battery, watts: b.flatMap { $0 >= 0 ? $0 : nil }))
        }
        inputs = sources
        outputs = sinks
        note = !usingAdapter && filling ? "电源状态切换中，等待下一次采样"
            : b == nil && hasBattery && usingAdapter && !charging ? "电池电流暂无数据，流向待确认" : nil
    }
}

enum BatteryTemperatureDisplay {
    static func celsius(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, (0...8000).contains(raw) else { return nil }
        return raw / 100
    }
}
