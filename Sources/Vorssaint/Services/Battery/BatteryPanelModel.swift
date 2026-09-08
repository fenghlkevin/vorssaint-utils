// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import IOKit

struct BatteryHistoryPoint: Codable, Identifiable {
    var date: Date
    var percent: Int
    var pluggedIn: Bool
    var id: Date { date }
}

/// Own sampling lifetime; does not enable or subscribe to the Power feature.
final class BatteryPanelModel: ObservableObject {
    static let shared = BatteryPanelModel()
    @Published private(set) var reading = PowerReading()
    @Published private(set) var temperature: Double?
    @Published private(set) var history: [BatteryHistoryPoint] = []
    @Published private(set) var apps: [ProcessUsage] = []
    @Published private(set) var appsLoading = false
    @Published private(set) var lastDischarge: Date?
    @Published private(set) var lastFullCharge: Date?
    @Published private(set) var observedAt = Date()
    private let queue = DispatchQueue(label: "com.vorssaint.battery-panel", qos: .utility)
    private lazy var sampler = PowerSampler(smc: SMCClient())
    private var timer: Timer?
    private var sampling = false
    private var visible = false
    private let historyKey = "batteryManagement.history.v1"
    private var previouslyDischarging: Bool?
    private var previouslyFull: Bool?
    private var lowAlert = BatteryLowAlertPolicy()
    private var previousNotificationState: String?
    private var historyDirty = false
    private var lastHistorySave = Date.distantPast
    private var terminationObserver: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([BatteryHistoryPoint].self, from: data) {
            history = saved.filter { $0.date > Date().addingTimeInterval(-43200) && $0.date <= Date() }
        }
        lastDischarge = defaults.object(forKey: "batteryManagement.lastDischarge") as? Date
        lastFullCharge = defaults.object(forKey: "batteryManagement.lastFullCharge") as? Date
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveHistory() }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = 5
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value { sample() }
    }

    func sample() {
        guard !sampling else { return }
        sampling = true
        let includeApps = visible && BatteryMenuField.apps.isVisible(
            hidden: UserDefaults.standard.string(forKey: DefaultsKey.batteryMenuHiddenFields) ?? "")
        if includeApps { appsLoading = true }
        queue.async {
            let reading = self.sampler.sample()
            let apps = includeApps ? ProcessUsageService.shared.topEnergy(limit: 3) : nil
            DispatchQueue.main.async {
                if self.reading != reading { self.reading = reading }
                if self.temperature != reading.temperature { self.temperature = reading.temperature }
                self.observedAt = Date()
                if let apps { self.apps = apps }
                self.appsLoading = false
                self.sampling = false
                self.record(reading, at: self.observedAt)
                self.notifyIfNeeded()
            }
        }
    }

    private func record(_ reading: PowerReading, at now: Date) {
        guard reading.hasBattery, let percent = reading.chargePercent, (0...100).contains(percent) else { return }
        let discharging = !reading.externalConnected || (reading.batteryWatts ?? 0) < -0.5
        let full = percent == 100
        // Only record observed transitions: don't invent earlier events on first launch.
        if previouslyDischarging == false && discharging {
            lastDischarge = now
            UserDefaults.standard.set(now, forKey: "batteryManagement.lastDischarge")
        }
        if previouslyFull == false && full {
            lastFullCharge = now
            UserDefaults.standard.set(now, forKey: "batteryManagement.lastFullCharge")
        }
        previouslyDischarging = discharging
        previouslyFull = full
        guard history.last.map({ now.timeIntervalSince($0.date) >= 60 }) ?? true else { return }
        history = history.filter { $0.date > now.addingTimeInterval(-43200) && $0.date <= now }
        history.append(.init(date: now, percent: percent, pluggedIn: reading.externalConnected))
        historyDirty = true
        if now.timeIntervalSince(lastHistorySave) >= 300 { saveHistory(at: now) }
    }

    private func saveHistory(at now: Date = Date()) {
        guard historyDirty, let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
        historyDirty = false
        lastHistorySave = now
    }

    var stateText: String {
        guard reading.hasBattery else { return "未检测到内置电池" }
        if reading.isCharging { return "充电中" }
        if !reading.externalConnected || (reading.batteryWatts ?? 0) < -0.5 { return "放电中" }
        return "已接通电源 · 未充电"
    }

    private func notifyIfNeeded() {
        let defaults = UserDefaults.standard
        guard AppFeature.batteryManagement.isAvailable, reading.hasBattery else {
            previousNotificationState = nil
            lowAlert = BatteryLowAlertPolicy()
            return
        }
        let state = stateText
        if let previous = previousNotificationState, previous != state,
           defaults.bool(forKey: DefaultsKey.batteryManagementNotifications) {
            Notifier.post(title: "电池状态已更改", body: state)
        }
        previousNotificationState = state
        let threshold = defaults.object(forKey: DefaultsKey.batteryLowNotificationThreshold) as? Int ?? 20
        let discharging = !reading.externalConnected || (reading.batteryWatts ?? 0) < -0.5
        if lowAlert.shouldNotify(percent: reading.chargePercent, discharging: discharging,
                                 enabled: defaults.bool(forKey: DefaultsKey.batteryLowNotification), threshold: threshold) {
            Notifier.post(title: "电池电量偏低", body: "剩余电量 \(reading.chargePercent ?? 0)%，请考虑连接电源。")
        }
    }

    var temperatureHelp: String {
        let source = reading.usesVirtualTemperature ? "VirtualTemperature" : "Temperature（回退）"
        let raw = reading.rawTemperature.map { String(format: "%.1f°C", $0) } ?? "—"
        return "显示来源：AppleSmartBattery.\(source)；原始 Temperature：\(raw)。温控保护仍使用原始 Temperature；每 30 秒及打开菜单时刷新。"
    }
}
