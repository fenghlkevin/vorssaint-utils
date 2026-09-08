// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreBluetooth
import CoreGraphics
import CoreWLAN
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

struct AwayLockPeripheral: Identifiable, Equatable { let id: UUID; var name: String; var rssi: Int; var lastSeen: Date }
struct AwayLockSelectedSignal: Identifiable { let id: String; let name: String; let rssi: Int?; let status: String }
struct AwayLockEvent: Identifiable, Codable {
    let id: UUID; let date: Date; let message: String
    init(_ message: String) { id = UUID(); date = Date(); self.message = message }
}
struct AwayLockProfile: Identifiable, Codable, Equatable {
    let id: UUID; var name: String; var selectedIDs: [String]; var primaryID: String; var policy: String
    var threshold: Int; var returnMargin: Int; var weakSeconds: Int; var lossSeconds: Int; var graceSeconds: Int
    var energyMode: String
}
enum AwayLockPolicy: String, CaseIterable, Identifiable {
    case allAway, anyAway, primaryAway, majorityAway
    var id: String { rawValue }
    var title: String {
        switch self { case .allAway: "全部离开时锁屏"; case .anyAway: "任一离开时锁屏"
        case .primaryAway: "主设备离开时锁屏"; case .majorityAway: "多数设备离开时锁屏" }
    }
}
enum AwayLockEnergyMode: String, CaseIterable, Identifiable {
    case off, balanced, maximum
    var id: String { rawValue }
    var title: String { self == .off ? "持续扫描" : (self == .balanced ? "平衡" : "极致节能") }
    var scanSeconds: TimeInterval { self == .maximum ? 3 : 4 }
    var pauseSeconds: TimeInterval { self == .maximum ? 12 : 6 }
}
private struct AwayLockDeviceSignal {
    var samples: [Int] = []; var firstSeen: Date?; var lastSeen: Date?; var wasNear = false
    mutating func record(_ value: Int, now: Date = Date()) {
        // A long silence starts a new observation session. Do not let an old,
        // previously stable session make a new one-shot advertisement look
        // reliable enough for absence-based locking.
        if let lastSeen, now.timeIntervalSince(lastSeen) > 60 {
            samples.removeAll(keepingCapacity: true); firstSeen = now; wasNear = false
        } else if firstSeen == nil { firstSeen = now }
        samples.append(value); if samples.count > 9 { samples.removeFirst() }; lastSeen = now
    }
    var median: Int? { AwayLockSupport.median(samples) }
}
private final class AwayLockAdvertisementThrottle: @unchecked Sendable {
    private let lock = NSLock(); private var lastForwarded: [UUID: TimeInterval] = [:]
    func shouldForward(_ id: UUID, interval: TimeInterval = 1) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime; lock.lock(); defer { lock.unlock() }
        if let last = lastForwarded[id], now - last < interval { return false }
        lastForwarded[id] = now
        if lastForwarded.count > 500 { lastForwarded = lastForwarded.filter { now - $0.value < 60 } }
        return true
    }
}

@MainActor
final class AwayLockService: NSObject, ObservableObject {
    static let shared = AwayLockService()
    enum State: Equatable { case disabled, needsDevice, scanning, nearby(Int), weak(Int), countdown(Int), awaitingReturn, bluetoothUnavailable }
    @Published private(set) var state: State = .disabled
    @Published private(set) var peripherals: [AwayLockPeripheral] = []
    @Published private(set) var events: [AwayLockEvent] = []
    @Published private(set) var profiles: [AwayLockProfile] = []
    @Published private(set) var calibrationMessage = "尚未开始"
    @Published private(set) var latestAggregateRSSI: Int?
    @Published private(set) var isRescanning = false
    private var central: CBCentralManager?; private var signals: [String: AwayLockDeviceSignal] = [:]
    private var evaluationTimer: Timer?; private var countdownTimer: Timer?; private var energyTimer: Timer?
    private var pendingPeripheralUpdates: [UUID: AwayLockPeripheral] = [:]
    private var peripheralFlushScheduled = false
    private var weakSince: Date?; private var waitingForReturn = false; private var nearCalibration: Int?
    private var learningSamples: [String: [Int]] = [:]; private var lastEnvironmentCheck = Date.distantPast
    private var lastDiagnosticCondition: String?
    private var monitoringWasActive = false
    private var wakeOnReturnArmed = false
    private var lastDisplayWakeAt = Date.distantPast
    private let displayWakeCooldown: TimeInterval = 120
    private let diagnosticSession = String(UUID().uuidString.prefix(8))
    private var diagnosticSequence = 0
    private var wakeRequestCount = 0
    private var lastLockRequestAt: Date?
    private var observedDisplayState = "未知（尚未收到系统通知）"
    private var displayRecoveryUntil = Date.distantPast
    private var lockWarningPresentedForCurrentAway = false
    private var lastLockWarningAt = Date.distantPast
    private let lockWarningCooldown: TimeInterval = 300
    private let lockWarningNotificationID = "com.vorssaint.away-lock.imminent"
    private nonisolated let advertisementThrottle = AwayLockAdvertisementThrottle()

    private override init() {
        super.init(); loadState()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
                self?.logSystemEvent("系统从睡眠中唤醒")
                self?.syncWithPreferences()
            } }
        let lifecycleEvents: [(Notification.Name, String, String?)] = [
            (NSWorkspace.willSleepNotification, "系统即将睡眠", nil),
            (NSWorkspace.screensDidSleepNotification, "显示器进入休眠", "休眠"),
            (NSWorkspace.screensDidWakeNotification, "显示器退出休眠", "唤醒")
        ]
        for (name, message, displayState) in lifecycleEvents {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let displayState {
                        self.observedDisplayState = displayState
                        if displayState == "唤醒" {
                            self.displayRecoveryUntil = Date().addingTimeInterval(15)
                            self.weakSince = nil
                            self.cancelCountdown()
                        }
                    }
                    self.logSystemEvent(message)
                }
            }
        }
    }
    var selectedIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.awayLockSelectedIDs) ?? [])
    }
    var primaryID: String { UserDefaults.standard.string(forKey: DefaultsKey.awayLockPrimaryID) ?? "" }
    var policy: AwayLockPolicy { AwayLockPolicy(rawValue: string(DefaultsKey.awayLockPolicy)) ?? .allAway }
    var pauseUntil: Date { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: DefaultsKey.awayLockPauseUntil)) }
    var isPaused: Bool { pauseUntil > Date() }
    var activeProfileID: UUID? { UUID(uuidString: string(DefaultsKey.awayLockActiveProfileID)) }
    var currentWiFiName: String { CWWiFiClient.shared().interface()?.ssid() ?? "未连接或无权限" }
    var currentPowerName: String { (IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?) ?? "未知" }
    var statusText: String {
        if isPaused { return "监测已暂停" }
        return switch state { case .disabled: "距离监测已关闭"; case .needsDevice: "请选择蓝牙设备"; case .scanning: "正在寻找目标设备"
        case .nearby: "设备就在附近"; case .weak: "设备可能已经离开"; case .countdown(let s): "将在 \(s) 秒后锁屏"
        case .awaitingReturn: "已请求锁屏，等待设备明确返回"
        case .bluetoothUnavailable: "蓝牙不可用" }
    }
    var detailText: String { latestAggregateRSSI.map { "聚合信号：\($0) dBm" } ?? "等待目标设备信号" }
    var selectedSignals: [AwayLockSelectedSignal] {
        selectedIDs.map { id in
            let signal = signals[id], lost = signal?.lastSeen.map { Date().timeIntervalSince($0) > Double(lossSeconds) } ?? false
            let status = lost ? "已失联" : ((signal?.median ?? -127) >= threshold(for: id) ? "附近" : "弱信号")
            return AwayLockSelectedSignal(id: id, name: displayName(id), rssi: signal?.median, status: status)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var settingsDevices: [AwayLockPeripheral] {
        var result = peripherals
        let selected = selectedIDs
        let aliases = aliases
        let rememberedNames = rememberedNames
        let present = Set(result.map { $0.id.uuidString })
        for id in selected where !present.contains(id) {
            guard let uuid = UUID(uuidString: id) else { continue }
            let name = aliases[id] ?? rememberedNames[id] ?? "已选设备"
            result.append(AwayLockPeripheral(id: uuid, name: name, rssi: 0, lastSeen: .distantPast))
        }
        return result.sorted { lhs, rhs in
            let lhsID = lhs.id.uuidString, rhsID = rhs.id.uuidString
            let lhsSelected = selected.contains(lhsID), rhsSelected = selected.contains(rhsID)
            if lhsSelected != rhsSelected { return lhsSelected }
            let lhsName = aliases[lhsID] ?? rememberedNames[lhsID] ?? lhs.name
            let rhsName = aliases[rhsID] ?? rememberedNames[rhsID] ?? rhs.name
            let comparison = lhsName.localizedStandardCompare(rhsName)
            return comparison == .orderedSame ? lhsID < rhsID : comparison == .orderedAscending
        }
    }

    func syncWithPreferences() {
        guard AppFeature.awayLock.isAvailable, bool(DefaultsKey.awayLockEnabled) else { stop(); return }
        if bool(DefaultsKey.awayLockNotifications) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }; startIfPossible()
    }
    func select(_ device: AwayLockPeripheral) {
        UserDefaults.standard.set([device.id.uuidString], forKey: DefaultsKey.awayLockSelectedIDs)
        UserDefaults.standard.set(device.id.uuidString, forKey: DefaultsKey.awayLockPeripheralID)
        UserDefaults.standard.set(device.name, forKey: DefaultsKey.awayLockPeripheralName)
        setPrimary(device.id.uuidString); resetEvaluation(); objectWillChange.send()
    }
    func toggleDevice(_ device: AwayLockPeripheral) {
        var ids = selectedIDs; let id = device.id.uuidString
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        UserDefaults.standard.set(Array(ids), forKey: DefaultsKey.awayLockSelectedIDs)
        if primaryID.isEmpty && ids.contains(id) { setPrimary(id) }; resetEvaluation(); objectWillChange.send()
    }
    func addDevice(identifier: UUID, name: String) {
        var ids = selectedIDs; ids.insert(identifier.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: DefaultsKey.awayLockSelectedIDs)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var names = rememberedNames; names[identifier.uuidString] = trimmed
            UserDefaults.standard.set(names, forKey: DefaultsKey.awayLockDeviceNames)
        }
        if primaryID.isEmpty { setPrimary(identifier.uuidString) }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if let peripheral = central?.retrievePeripherals(withIdentifiers: [identifier]).first {
            let resolvedName = trimmed.isEmpty ? (peripheral.name ?? "已添加设备") : trimmed
            if !peripherals.contains(where: { $0.id == identifier }) {
                peripherals.append(AwayLockPeripheral(id: identifier, name: resolvedName,
                                                       rssi: 0, lastSeen: .distantPast))
            }
        }
        resetEvaluation(); startIfPossible(); objectWillChange.send()
    }
    func setPrimary(_ id: String) { UserDefaults.standard.set(id, forKey: DefaultsKey.awayLockPrimaryID); objectWillChange.send() }
    func setPolicy(_ policy: AwayLockPolicy) { UserDefaults.standard.set(policy.rawValue, forKey: DefaultsKey.awayLockPolicy); resetEvaluation(); objectWillChange.send() }
    func setAlias(_ alias: String, for id: String) {
        var values = aliases; if alias.isEmpty { values.removeValue(forKey: id) } else { values[id] = alias }
        UserDefaults.standard.set(values, forKey: DefaultsKey.awayLockDeviceAliases); objectWillChange.send()
    }
    func setThreshold(_ value: Int?, for id: String) {
        var values = customThresholds; if let value { values[id] = Double(value) } else { values.removeValue(forKey: id) }
        UserDefaults.standard.set(values, forKey: DefaultsKey.awayLockPerDeviceThresholds); objectWillChange.send()
    }
    func hasCustomThreshold(_ id: String) -> Bool { customThresholds[id] != nil }
    func thresholdSource(_ id: String) -> String {
        if customThresholds[id] != nil { return "自定义" }
        if learnedThresholds[id] != nil { return "自动学习" }
        return "跟随默认"
    }
    func threshold(for id: String) -> Int {
        Int(customThresholds[id] ?? learnedThresholds[id] ?? Double(integer(DefaultsKey.awayLockThreshold)))
    }
    func displayName(_ id: String) -> String { aliases[id] ?? rememberedNames[id] ?? peripherals.first { $0.id.uuidString == id }?.name ?? "已选设备" }
    func rescan() { isRescanning = true; central?.stopScan(); startIfPossible(); DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.isRescanning = false } }
    func removeStaleDevices() { peripherals.removeAll { Date().timeIntervalSince($0.lastSeen) > 300 && !selectedIDs.contains($0.id.uuidString) } }
    func pause(minutes: Int) { setPause(Date().addingTimeInterval(Double(minutes * 60))); log("监测暂停 \(minutes) 分钟") }
    func pauseForToday() { setPause(Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date()) ?? Date()) }
    func resumeNow() { setPause(.distantPast); log("监测已恢复") }
    func startNearCalibration() { calibrate(near: true) }; func startFarCalibration() { calibrate(near: false) }
    func addProfile(named name: String) { profiles.append(profile(UUID(), name)); saveProfiles(); applyProfile(profiles.last!.id) }
    func updateActiveProfile() { guard let id = activeProfileID, let i = profiles.firstIndex(where: { $0.id == id }) else { return }; profiles[i] = profile(id, profiles[i].name); saveProfiles() }
    func deleteActiveProfile() { guard let id = activeProfileID else { return }; profiles.removeAll { $0.id == id }; saveProfiles(); UserDefaults.standard.set("", forKey: DefaultsKey.awayLockActiveProfileID) }
    func applyProfile(_ id: UUID) {
        guard let p = profiles.first(where: { $0.id == id }) else { return }; let d = UserDefaults.standard
        d.set(p.selectedIDs, forKey: DefaultsKey.awayLockSelectedIDs); d.set(p.primaryID, forKey: DefaultsKey.awayLockPrimaryID)
        d.set(p.policy, forKey: DefaultsKey.awayLockPolicy); d.set(p.threshold, forKey: DefaultsKey.awayLockThreshold)
        d.set(p.returnMargin, forKey: DefaultsKey.awayLockReturnMargin); d.set(p.weakSeconds, forKey: DefaultsKey.awayLockWeakSeconds)
        d.set(p.lossSeconds, forKey: DefaultsKey.awayLockSignalLossSeconds); d.set(p.graceSeconds, forKey: DefaultsKey.awayLockGraceSeconds)
        d.set(p.energyMode, forKey: DefaultsKey.awayLockEnergyMode); d.set(id.uuidString, forKey: DefaultsKey.awayLockActiveProfileID)
        resetEvaluation(); objectWillChange.send()
    }
    func bindCurrentEnvironment() {
        guard let id = activeProfileID else { return }; let d = UserDefaults.standard; var w = dictionary(DefaultsKey.awayLockWiFiRules); var p = dictionary(DefaultsKey.awayLockPowerRules)
        w[id.uuidString] = currentWiFiName; p[id.uuidString] = currentPowerName; d.set(w, forKey: DefaultsKey.awayLockWiFiRules); d.set(p, forKey: DefaultsKey.awayLockPowerRules)
    }
    func clearEvents() { events.removeAll(); saveEvents() }
    func copyEvents() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let text = events.reversed().map { "\(formatter.string(from: $0.date)) \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func startIfPossible() {
        guard AppFeature.awayLock.isAvailable, bool(DefaultsKey.awayLockEnabled) else { return }
        guard let central, central.state == .poweredOn else {
            if central?.state == .unknown {
                state = .scanning
                logCondition("bluetooth-initializing", "蓝牙状态正在初始化，尚未开始判定（不代表蓝牙不可用）")
            } else {
                state = .bluetoothUnavailable
                logCondition("bluetooth-unavailable", "蓝牙不可用，离开锁屏正在等待蓝牙恢复")
            }
            return
        }
        if !central.isScanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        if evaluationTimer == nil { evaluationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.evaluate() } } }
        state = selectedIDs.isEmpty ? .needsDevice : .scanning; scheduleEnergyPause()
        if !monitoringWasActive {
            monitoringWasActive = true
            let count = selectedIDs.count
            log("监测已启动：\(count) 台目标设备，策略“\(policy.title)”")
        }
        if selectedIDs.isEmpty { logCondition("needs-device", "尚未选择目标设备，监测正在等待配置") }
    }
    private func evaluate(now: Date = Date()) {
        guard !isPaused else { cancelCountdown(); return }; applyEnvironment(now)
        let ids = selectedIDs; guard !ids.isEmpty else { state = .needsDevice; return }
        let snapshots = ids.map { id -> (String, Bool, Int?, Bool) in
            guard var s = signals[id] else { return (id, false, nil, false) }; let lost = s.lastSeen.map { now.timeIntervalSince($0) >= Double(lossSeconds) } ?? false
            let lossIsReliable = !lost || AwayLockSupport.canInferDepartureFromSilence(
                firstSeen: s.firstSeen, lastSeen: s.lastSeen,
                requiredObservationSeconds: lossSeconds)
            let near = !lost && s.median.map { AwayLockSupport.isNear(rssi: $0, threshold: threshold(for: id), returnMargin: returnMargin, wasNear: s.wasNear) } == true
            if !lost { s.wasNear = near }; signals[id] = s
            return (id, near, s.median, lossIsReliable)
        }
        latestAggregateRSSI = snapshots.compactMap(\.2).max(); let away = snapshots.filter { !$0.1 }.count
        // An unknown device must never be interpreted as away. This covers the
        // initial scan as well as peripherals that emit only a short discovery
        // burst and then remain quiet while still beside the Mac.
        let reliable = snapshots.filter(\.3)
        let shouldLock: Bool = switch policy {
        case .allAway: reliable.count == snapshots.count && away == snapshots.count
        case .anyAway: reliable.contains { !$0.1 }
        case .primaryAway: snapshots.first { $0.0 == primaryID }.map { $0.3 && !$0.1 } ?? false
        case .majorityAway: reliable.count == snapshots.count && away > snapshots.count / 2
        }
        let confirmedReturn = AwayLockSupport.hasConfirmedReturn(
            policy: policy.rawValue, primaryID: primaryID,
            readings: snapshots.map { (id: $0.0, near: $0.1) })
        if waitingForReturn && !confirmedReturn {
            weakSince = nil; cancelCountdown(); state = .awaitingReturn
            logCondition("awaiting-confirmed-return",
                         "已发送过锁屏请求，正在等待设备明确返回；不会重复锁屏或唤醒。当前：\(signalSummary(snapshots, now: now))")
            return
        }
        if !shouldLock {
            let returned = waitingForReturn; let wasSuspectedAway = weakSince != nil || countdownTimer != nil
            if lockWarningPresentedForCurrentAway {
                lockWarningPresentedForCurrentAway = false
                clearLockWarningNotification()
            }
            waitingForReturn = false; weakSince = nil; cancelCountdown(); state = .nearby(latestAggregateRSSI ?? 0); learn(snapshots)
            let summary = signalSummary(snapshots, now: now)
            if returned {
                logCondition("returned", "设备已返回：\(summary)")
                let shouldWake = wakeOnReturnArmed
                log("返回唤醒检查：\(diagnosticContext)；设备详情：\(summary)")
                wakeOnReturnArmed = false
                if shouldWake { wakeDisplay(now: now) }
                else { log("返回唤醒跳过：没有本功能锁屏请求授予的唤醒资格") }
                notify("设备已返回", "目标蓝牙设备重新靠近 Mac")
            } else if wasSuspectedAway {
                logCondition("nearby", "锁屏已取消，设备恢复到附近：\(summary)")
            } else {
                lastDiagnosticCondition = "nearby"
            }
            return
        }
        guard snapshots.contains(where: { $0.2 != nil }) else {
            state = .scanning
            logCondition("waiting-signal", "尚未收到目标设备信号，继续扫描且不会触发锁屏")
            return
        }
        if let reason = protectionReason {
            weakSince = nil; cancelCountdown()
            let trigger = signalSummary(snapshots, now: now)
            logCondition("protected:\(reason)", "策略“\(policy.title)”已满足，本应进入锁屏判断：\(trigger)；但已暂缓锁屏：\(reason)")
            return
        }
        if weakSince == nil {
            weakSince = now
            logCondition("weak", "策略“\(policy.title)”已满足：\(signalSummary(snapshots, now: now))；持续 \(weakSeconds) 秒后进入倒计时")
        }
        let remaining = max(0, weakSeconds - Int(now.timeIntervalSince(weakSince!))); state = .weak(remaining)
        if AwayLockSupport.shouldStartCountdown(weakSince: weakSince, now: now, requiredSeconds: weakSeconds) { beginCountdown() }
    }
    private func beginCountdown() {
        guard countdownTimer == nil else { return }; var remaining = max(1, graceSeconds); state = .countdown(remaining); log("离开条件已确认，开始 \(remaining) 秒锁屏倒计时")
        presentLockWarningIfNeeded()
        if bool(DefaultsKey.awayLockShowCountdown) { AwayLockCountdownOverlay.shared.show(seconds: remaining) { [weak self] in
            guard let self else { return }
            self.weakSince = Date(); self.cancelCountdown(); self.log("用户取消了本次锁屏倒计时")
        } }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in Task { @MainActor in
            guard let self else { timer.invalidate(); return }; if let reason = self.protectionReason {
                self.weakSince = Date(); self.cancelCountdown(); self.logCondition("protected:\(reason)", "倒计时已取消：\(reason)"); return
            }
            remaining -= 1; if remaining <= 0 { timer.invalidate(); self.countdownTimer = nil; AwayLockCountdownOverlay.shared.hide()
                let didRequestLock = self.bool(DefaultsKey.awayLockAutomaticLock)
                self.wakeOnReturnArmed = didRequestLock
                if didRequestLock {
                    self.log("即将发送自动锁屏请求：\(self.diagnosticContext)")
                    self.lastLockRequestAt = Date()
                    QuickTogglesService.shared.lockScreen()
                    self.log("自动锁屏调用已返回（不代表系统已确认锁定）；下一次设备返回具有唤醒资格")
                }
                else { self.log("倒计时结束，但自动锁屏已关闭，未执行锁定，也不会在设备返回时唤醒显示器") }
                self.waitingForReturn = true; self.weakSince = nil
            } else { self.state = .countdown(remaining); AwayLockCountdownOverlay.shared.update(seconds: remaining) }
        } }
    }
    private var protectionReason: String? {
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
            return "系统会话已经锁定，不再发送锁屏请求"
        }
        if Date() < displayRecoveryUntil {
            return "显示器正在恢复，15 秒保护期间不重新锁屏"
        }
        if bool(DefaultsKey.awayLockProtectRecentInput) {
            let k = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown), m = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
            if min(k, m) < 3 { return "检测到最近的键盘或鼠标操作" }
        }
        guard bool(DefaultsKey.awayLockPreventPresentation), let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier else { return nil }
        let builtIn = ["us.zoom.xos", "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord"]
        if Set(builtIn + (UserDefaults.standard.stringArray(forKey: DefaultsKey.awayLockProtectedApps) ?? [])).contains(id) {
            return "前台应用“\(app.localizedName ?? id)”处于防误锁名单"
        }
        if frontmostWindowIsFullScreen { return "前台窗口正在全屏显示" }
        return nil
    }
    private var frontmostWindowIsFullScreen: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let info = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: info) else { return false }
            return NSScreen.screens.contains { abs($0.frame.width - bounds.width) < 3 && abs($0.frame.height - bounds.height) < 3 }
        }
    }
    private func calibrate(near: Bool) {
        let values = selectedIDs.compactMap { signals[$0]?.median }; guard let median = AwayLockSupport.median(values) else { calibrationMessage = "尚未收到目标设备信号"; return }
        if near { nearCalibration = median; calibrationMessage = "座位信号完成，请到离席位置采集" }
        else if let n = nearCalibration { UserDefaults.standard.set((n + median) / 2, forKey: DefaultsKey.awayLockThreshold); calibrationMessage = "校准完成" }
        else { calibrationMessage = "请先采集座位信号" }
    }
    private func learn(_ snapshots: [(String, Bool, Int?, Bool)]) {
        guard bool(DefaultsKey.awayLockAutomaticLearning) else { return }; var learned = learnedThresholds
        for (id, near, rssi, _) in snapshots where near && customThresholds[id] == nil { guard let rssi else { continue }; learningSamples[id, default: []].append(rssi)
            if learningSamples[id, default: []].count > 30 { learningSamples[id]?.removeFirst() }; if let m = AwayLockSupport.median(learningSamples[id] ?? []), (learningSamples[id]?.count ?? 0) >= 10 { learned[id] = Double(max(-90, min(-55, m - 12))) } }
        if learned != learnedThresholds {
            UserDefaults.standard.set(learned, forKey: DefaultsKey.awayLockLearnedThresholds)
        }
    }
    private func scheduleEnergyPause() {
        energyTimer?.invalidate()
        energyTimer = nil
        let mode = AwayLockEnergyMode(rawValue: string(DefaultsKey.awayLockEnergyMode)) ?? .balanced
        guard mode != .off else { return }
        energyTimer = Timer.scheduledTimer(withTimeInterval: mode.scanSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitoringWasActive,
                      AppFeature.awayLock.isAvailable, self.bool(DefaultsKey.awayLockEnabled) else { return }
                let now = Date()
                // Keep listening during uncertain departure, discovery and return.
                // A pause must end before any target's silence timeout expires.
                let canPause = AwayLockSupport.canPauseScan(
                    readings: self.selectedIDs.map { id in
                        (near: self.signals[id]?.wasNear == true, lastSeen: self.signals[id]?.lastSeen)
                    }, now: now, pauseSeconds: mode.pauseSeconds, scanSeconds: mode.scanSeconds,
                    lossSeconds: self.lossSeconds,
                    requiresContinuousScan: self.isRescanning || self.waitingForReturn
                        || self.weakSince != nil || self.countdownTimer != nil)
                guard canPause else {
                    self.scheduleEnergyPause()
                    return
                }
                self.central?.stopScan()
                self.energyTimer = Timer.scheduledTimer(withTimeInterval: mode.pauseSeconds, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.startIfPossible() }
                }
            }
        }
    }
    private func applyEnvironment(_ now: Date) {
        guard bool(DefaultsKey.awayLockAutomaticScenes), now.timeIntervalSince(lastEnvironmentCheck) > 30 else { return }; lastEnvironmentCheck = now
        let w = dictionary(DefaultsKey.awayLockWiFiRules), p = dictionary(DefaultsKey.awayLockPowerRules)
        if let found = profiles.first(where: { w[$0.id.uuidString] == currentWiFiName || p[$0.id.uuidString] == currentPowerName }), found.id != activeProfileID { applyProfile(found.id) }
    }
    private func wakeDisplay(now: Date) {
        guard bool(DefaultsKey.awayLockWakeOnReturn) else {
            log("设备已返回，但“设备靠近时唤醒显示器”已关闭，未执行唤醒")
            return
        }
        let elapsed = now.timeIntervalSince(lastDisplayWakeAt)
        guard elapsed >= displayWakeCooldown else {
            let remaining = Int((displayWakeCooldown - elapsed).rounded(.up))
            log("设备已返回，但为防止反复亮屏，本次唤醒已抑制（冷却剩余 \(remaining) 秒）")
            return
        }
        let displayPower = displayPowerSnapshot
        guard displayPower.allOnlineDisplaysAsleep else {
            log("设备已明确返回，但未发送唤醒请求：\(displayPower.description)。显示器已经亮着时唤醒可能导致闪烁")
            return
        }
        var id: IOPMAssertionID = 0
        wakeRequestCount += 1
        log("发送显示器唤醒请求 #\(wakeRequestCount)：\(diagnosticContext)")
        let result = IOPMAssertionDeclareUserActivity("Vorssaint Away Lock" as CFString, kIOPMUserActiveLocal, &id)
        log("显示器唤醒请求 #\(wakeRequestCount) 返回：IOKit=\(result)，assertionID=\(id)；接口返回不等于屏幕已稳定点亮")
        if result == kIOReturnSuccess {
            lastDisplayWakeAt = now
            displayRecoveryUntil = now.addingTimeInterval(15)
            log("显示器唤醒请求已接受（120 秒内不再重复唤醒）；等待系统显示器状态通知")
        } else {
            log("设备返回后的显示器唤醒请求失败（IOKit 错误 \(result)）")
        }
    }
    private var displayPowerSnapshot: (allOnlineDisplaysAsleep: Bool, description: String) {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return (false, "无法读取在线显示器电源状态，按安全策略跳过唤醒")
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return (false, "读取在线显示器电源状态失败，按安全策略跳过唤醒")
        }
        displays = Array(displays.prefix(Int(count)))
        let asleep = displays.filter { CGDisplayIsAsleep($0) != 0 }.count
        return (asleep == displays.count,
                "在线显示器 \(displays.count) 台，其中休眠 \(asleep) 台、亮屏 \(displays.count - asleep) 台")
    }
    private func notify(_ title: String, _ body: String) { guard bool(DefaultsKey.awayLockNotifications) else { return }; let c = UNMutableNotificationContent(); c.title = title; c.body = body; UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) }
    private func presentLockWarningIfNeeded(now: Date = Date()) {
        guard !lockWarningPresentedForCurrentAway else {
            logCondition("lock-warning-deduplicated", "锁屏倒计时再次开始，但同一次离开过程已通知，不再重复发送")
            return
        }
        lockWarningPresentedForCurrentAway = true
        let elapsed = now.timeIntervalSince(lastLockWarningAt)
        guard elapsed >= lockWarningCooldown else {
            let remaining = Int((lockWarningCooldown - elapsed).rounded(.up))
            logCondition("lock-warning-cooldown", "锁屏倒计时再次开始，但通知仍在 5 分钟冷却期内（剩余 \(remaining) 秒），不再重复发送")
            return
        }
        lastLockWarningAt = now
        if bool(DefaultsKey.awayLockNotificationSound) { NSSound.beep() }
        guard bool(DefaultsKey.awayLockNotifications) else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [lockWarningNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [lockWarningNotificationID])
        let content = UNMutableNotificationContent()
        content.title = "即将锁定 Mac"; content.body = "目标蓝牙设备已经离开"
        center.add(UNNotificationRequest(identifier: lockWarningNotificationID, content: content, trigger: nil))
    }
    private func clearLockWarningNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [lockWarningNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [lockWarningNotificationID])
    }
    private func setPause(_ date: Date) { UserDefaults.standard.set(date.timeIntervalSince1970, forKey: DefaultsKey.awayLockPauseUntil); cancelCountdown(); objectWillChange.send() }
    private var diagnosticContext: String {
        let now = Date()
        let lockAge = lastLockRequestAt.map { String(format: "%.1f 秒", now.timeIntervalSince($0)) } ?? "本次运行未请求"
        let wakeAge = lastDisplayWakeAt == .distantPast ? "本次运行未成功请求" : String(format: "%.1f 秒", now.timeIntervalSince(lastDisplayWakeAt))
        return "显示器=\(observedDisplayState)，状态=\(state)，等待返回=\(waitingForReturn)，唤醒资格=\(wakeOnReturnArmed)，唤醒开关=\(bool(DefaultsKey.awayLockWakeOnReturn))，倒计时运行=\(countdownTimer != nil)，扫描中=\(central?.isScanning == true)，距锁屏请求=\(lockAge)，距唤醒请求=\(wakeAge)"
    }
    private func logSystemEvent(_ message: String) {
        guard monitoringWasActive || bool(DefaultsKey.awayLockEnabled) else { return }
        log("系统事件：\(message)；\(diagnosticContext)（系统通知不能证明由本功能触发）")
    }
    private func log(_ message: String) {
        diagnosticSequence += 1
        events.insert(AwayLockEvent("[\(diagnosticSession)/\(diagnosticSequence)] \(message)"), at: 0)
        if events.count > 1000 { events.removeLast(events.count - 1000) }
        saveEvents()
    }
    private func logCondition(_ condition: String, _ message: String) {
        guard lastDiagnosticCondition != condition else { return }
        lastDiagnosticCondition = condition; log(message)
    }
    private func signalSummary(_ snapshots: [(String, Bool, Int?, Bool)], now: Date) -> String {
        snapshots.map { id, near, rssi, reliable in
            let name = displayName(id)
            let threshold = threshold(for: id)
            guard let signal = signals[id], let lastSeen = signal.lastSeen else {
                return "\(name)：尚未收到广播（不会按失联锁屏）"
            }
            let silentSeconds = max(0, Int(now.timeIntervalSince(lastSeen).rounded(.down)))
            let lastValue = rssi.map { "\($0) dBm" } ?? "未知"
            if silentSeconds >= lossSeconds {
                let reliability = reliable ? "已判定失联" : "观测时间不足，暂不判定失联"
                return "\(name)：\(reliability)，已 \(silentSeconds) 秒未收到广播（失联判定线 \(lossSeconds) 秒）；最后信号 \(lastValue)，离开阈值 \(threshold) dBm"
            }
            if near {
                return "\(name)：附近，\(silentSeconds) 秒前收到广播，信号 \(lastValue)（离开阈值 \(threshold) dBm）"
            }
            let returnThreshold = threshold + returnMargin
            return "\(name)：弱信号，\(silentSeconds) 秒前收到广播，信号 \(lastValue)（离开阈值 \(threshold) dBm，返回判定线 \(returnThreshold) dBm）"
        }.sorted().joined(separator: "；")
    }
    private func cancelCountdown() { countdownTimer?.invalidate(); countdownTimer = nil; AwayLockCountdownOverlay.shared.hide() }
    private func resetEvaluation() { weakSince = nil; waitingForReturn = false; wakeOnReturnArmed = false; lockWarningPresentedForCurrentAway = false; cancelCountdown() }
    private func stop() {
        central?.stopScan(); evaluationTimer?.invalidate(); evaluationTimer = nil; energyTimer?.invalidate(); energyTimer = nil
        resetEvaluation(); state = .disabled; lastDiagnosticCondition = nil
        if monitoringWasActive { monitoringWasActive = false; log("监测已停止") }
    }
    private func queuePeripheralUpdate(_ reading: AwayLockPeripheral) {
        pendingPeripheralUpdates[reading.id] = reading
        guard !peripheralFlushScheduled else { return }
        peripheralFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.flushPeripheralUpdates()
        }
    }
    private func flushPeripheralUpdates() {
        peripheralFlushScheduled = false
        guard !pendingPeripheralUpdates.isEmpty else { return }
        let updates = pendingPeripheralUpdates
        pendingPeripheralUpdates.removeAll(keepingCapacity: true)
        var merged = Dictionary(uniqueKeysWithValues: peripherals.map { ($0.id, $0) })
        for (id, reading) in updates { merged[id] = reading }
        let selected = selectedIDs
        // Nearby BLE advertisements can use rotating identifiers. Keep the
        // settings list bounded while never evicting a device selected by the user.
        peripherals = merged.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .reduce(into: [AwayLockPeripheral]()) { result, device in
                if selected.contains(device.id.uuidString) || result.count < 80 {
                    result.append(device)
                }
            }
    }
    private var returnMargin: Int { integer(DefaultsKey.awayLockReturnMargin) }; private var weakSeconds: Int { integer(DefaultsKey.awayLockWeakSeconds) }
    private var lossSeconds: Int { integer(DefaultsKey.awayLockSignalLossSeconds) }; private var graceSeconds: Int { integer(DefaultsKey.awayLockGraceSeconds) }
    private var aliases: [String: String] { dictionary(DefaultsKey.awayLockDeviceAliases) }; private var customThresholds: [String: Double] { UserDefaults.standard.dictionary(forKey: DefaultsKey.awayLockPerDeviceThresholds) as? [String: Double] ?? [:] }
    private var rememberedNames: [String: String] { dictionary(DefaultsKey.awayLockDeviceNames) }
    private var learnedThresholds: [String: Double] { UserDefaults.standard.dictionary(forKey: DefaultsKey.awayLockLearnedThresholds) as? [String: Double] ?? [:] }
    private func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }; private func integer(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
    private func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }; private func dictionary(_ key: String) -> [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
    private func profile(_ id: UUID, _ name: String) -> AwayLockProfile { AwayLockProfile(id: id, name: name, selectedIDs: Array(selectedIDs), primaryID: primaryID, policy: policy.rawValue, threshold: integer(DefaultsKey.awayLockThreshold), returnMargin: returnMargin, weakSeconds: weakSeconds, lossSeconds: lossSeconds, graceSeconds: graceSeconds, energyMode: string(DefaultsKey.awayLockEnergyMode)) }
    private func loadState() { if let data = UserDefaults.standard.data(forKey: DefaultsKey.awayLockProfiles) { profiles = (try? JSONDecoder().decode([AwayLockProfile].self, from: data)) ?? [] }; if let data = UserDefaults.standard.data(forKey: DefaultsKey.awayLockEvents) { events = (try? JSONDecoder().decode([AwayLockEvent].self, from: data)) ?? [] } }
    private func saveProfiles() { UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: DefaultsKey.awayLockProfiles) }; private func saveEvents() { UserDefaults.standard.set(try? JSONEncoder().encode(events), forKey: DefaultsKey.awayLockEvents) }
}

extension AwayLockService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) { Task { @MainActor in self.startIfPossible() } }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier, value = RSSI.intValue; guard value < 0, advertisementThrottle.shouldForward(id) else { return }; let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名设备"
        Task { @MainActor in let reading = AwayLockPeripheral(id: id, name: name, rssi: value, lastSeen: Date()); self.queuePeripheralUpdate(reading)
            if name != "未命名设备" { var names = self.dictionary(DefaultsKey.awayLockDeviceNames); if names[id.uuidString] != name { names[id.uuidString] = name; UserDefaults.standard.set(names, forKey: DefaultsKey.awayLockDeviceNames) } }
            if self.selectedIDs.contains(id.uuidString) { var signal = self.signals[id.uuidString] ?? AwayLockDeviceSignal(); signal.record(value); self.signals[id.uuidString] = signal } }
    }
}
