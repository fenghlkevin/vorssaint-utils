// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import ServiceManagement
import OSLog

/// Only the independent privileged helper writes charging keys.
final class BatteryManagementService: ObservableObject {
    @Published private(set) var diagnosticEvents: [String] = UserDefaults.standard.stringArray(forKey: "battery.diagnosticEvents") ?? []
    private let diagnosticSession = UUID().uuidString
    private var diagnosticSequence = 0
    private var telemetryEvents = UserDefaults.standard.stringArray(forKey: "battery.telemetryEvents.v1") ?? []
    private var telemetryTracker = BatteryTelemetryTracker()
    @Published private(set) var latestPowerObservation: String?
    private var lastConfigurationLog: String?
    private var allDiagnosticEvents: [String] { (diagnosticEvents + telemetryEvents).sorted(by: >) }

    func recordPowerObservation(_ reading: PowerReading, at date: Date) {
        let change = telemetryTracker.observe(at: date, percent: reading.chargePercent,
            external: reading.externalConnected, charging: reading.isCharging, watts: reading.batteryWatts)
        let responseAge = lastBackendResponse.map { String(Int(max(0, date.timeIntervalSince($0)))) } ?? "未知"
        let entry = "\(date.ISO8601Format()) [电池采样/\(diagnosticSession)] \(change)；\(reading.batteryDiagnosticValues)；应用模式=\(mode.rawValue) 有效上限=\(effectiveLimit)% 后台就绪=\(backendReady) 后台响应距今=\(responseAge)s；\(lastError ?? "无连接错误")"
        telemetryEvents.insert(entry, at: 0)
        latestPowerObservation = entry
        telemetryEvents = Array(telemetryEvents.prefix(3000))
        UserDefaults.standard.set(telemetryEvents, forKey: "battery.telemetryEvents.v1")
        Self.connectionLog.info("\(entry, privacy: .public)")
    }
    private func record(_ message: String) {
        diagnosticSequence += 1
        let entry = "\(Date().ISO8601Format()) [\(diagnosticSession)/\(diagnosticSequence)] \(message)"
        diagnosticEvents.insert(entry, at: 0)
        diagnosticEvents = Array(diagnosticEvents.prefix(1000))
        UserDefaults.standard.set(diagnosticEvents, forKey: "battery.diagnosticEvents")
        Self.connectionLog.notice("\(entry, privacy: .public)")
    }
    func copyDiagnosticEvents() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allDiagnosticEvents.joined(separator: "\n"), forType: .string)
    }
    func clearDiagnosticEvents() {
        diagnosticEvents = []
        UserDefaults.standard.removeObject(forKey: "battery.diagnosticEvents")
        telemetryEvents = []
        latestPowerObservation = nil
        telemetryTracker = BatteryTelemetryTracker()
        lastConfigurationLog = nil
        UserDefaults.standard.removeObject(forKey: "battery.telemetryEvents.v1")
    }
    static let shared = BatteryManagementService()
    enum Mode: String { case automatic, limited, forceCharge, inhibiting, discharging, unavailable }
    @Published private(set) var snapshot: BatteryInfo?
    @Published private(set) var mode: Mode = .automatic
    @Published private(set) var lastError: String?
    @Published private(set) var warning: String?
    /// Older/current helpers also send informational state in `warning`.
    /// Hide only these known notices; real warnings remain visible and logged.
    var actionableWarning: String? {
        guard let warning else { return nil }
        if systemChargeLimitBackend && ["系统限充需要确认：", "系统上限已回读 ", "上限请求已发送，等待系统回读；"]
            .contains(where: { warning.hasPrefix($0) }) { return nil }
        return warning
    }
    @Published private(set) var accessText = "后台未授权"
    @Published private(set) var backendReady = false
    @Published private(set) var systemChargeLimitBackend = false
    @Published private(set) var systemChargeLimits: [Int] = []
    @Published private(set) var systemLimitReadback: Int?
    @Published private(set) var systemPolicyLimit: Int?
    var systemLimitConsent: Bool { UserDefaults.standard.bool(forKey: "batteryManagement.allowSystemChargeLimit") }
    func setSystemLimitConsent(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: "batteryManagement.allowSystemChargeLimit")
        record(allowed ? "用户确认系统限充：仅管理上限，不接管开关、主动放电或自定义温控" : "用户关闭系统限充：请求恢复之前的上限")
        suspendedAfterFailure = false
        refresh()
    }
    @Published private(set) var interfaceUnavailable = false
    private var interfaceDiagnostics = "尚未收到接口诊断"
    var needsSystemChargeManagement: Bool {
        isEnabled && verifiedConnection && connection != nil && interfaceUnavailable
            && !versionMismatch && !signingMismatch && !recoveryBlocked
    }
    func openSystemBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else { return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
    @Published private(set) var ledSupported = false
    @Published private(set) var dischargeSupported = false
    @Published private(set) var needsTakeover = false
    @Published private(set) var backendName: String?
    @Published private(set) var activeRule: String?
    @Published private(set) var effectiveLimit = 80
    @Published private(set) var thermalPause = false
    @Published private(set) var working = false
    /// Visible busy state for an action initiated by the user. Periodic XPC
    /// synchronization intentionally does not toggle this value.
    @Published private(set) var performingUserAction = false
    @Published private(set) var repairPhase: String?
    @Published private(set) var recoveryBlocked = false
    @Published private(set) var versionMismatch = false
    @Published private(set) var peerCodeHash: String?
    @Published private(set) var lastBackendResponse: Date?
    @Published private(set) var lastManualCheck: Date?
    @Published private(set) var launchDiagnosis = "尚未检查系统启动状态"
    @Published private(set) var signingMismatch = false
    @Published private(set) var offersPrivilegedRepair = false
    private var launchRepairAttempted = false

    var permissionSummary: String {
        switch daemonStatus {
        case .enabled: return "已授权"
        case .requiresApproval: return "等待允许"
        case .notRegistered: return "未注册"
        default: return "待检查"
        }
    }
    var connectionSummary: String {
        connection != nil && verifiedConnection ? "已连接" : "尚未确认"
    }
    var versionSummary: String {
        if signingMismatch { return "签名身份不一致" }
        if versionMismatch { return "不一致" }
        return connection != nil && verifiedConnection ? "验证通过" : "等待连接确认"
    }
    var diagnosisTitle: String {
        if let repairPhase { return repairPhase }
        if !isEnabled { return "电池管理已关闭" }
        if daemonStatus == .requiresApproval { return "需要允许电池后台运行" }
        if signingMismatch { return "App 与运行中后台的签名不一致" }
        if recoveryBlocked { return "暂时无法安全更新后台" }
        if versionMismatch { return "电池后台需要更新" }
        if daemonStatus == .notRegistered { return "电池后台尚未注册" }
        if needsSystemChargeManagement { return "当前固件接口尚未适配，App充电上限未生效" }
        if lastError != nil { return verifiedConnection && connection != nil ? "充电控制需要检查" : "电池后台连接异常" }
        return backendReady ? "电池后台已连接" : "正在确认后台状态"
    }
    var diagnosisDescription: String {
        if signingMismatch { return "后台仍在运行，但不接受当前 App 的签名。优先使用原证书重新签名安装；需要迁移签名时，可在管理员授权后强制修复注册。" }
        if recoveryBlocked { return "旧后台没有确认恢复系统充电。已停止更新，保留后台与恢复记录。" }
        if !isEnabled { return "不自动接管充电；关闭不代表已确认硬件恢复，请查看诊断记录。" }
        if systemChargeLimitBackend && lastError == nil { return "电池后台正常，已识别系统限充接口。请在下方选择百分比并启用充电上限。" }
        if daemonStatus == .requiresApproval { return "请在系统设置中允许 Vorssaint 后台运行；返回后自动检查。" }
        if needsSystemChargeManagement {
            return "后台连接正常，但未识别到可安全控制的充电接口。重新授权不能解决接口兼容问题。请在系统电池设置中配置充电上限；本App继续监测，不代表已接管或确认系统限充。温度等缺失数据保持未知。"
        }
        if let lastError { return lastError }
        return backendReady ? statusText : "电池信息可独立读取；注册成功不代表充电控制已经生效。"
    }
    var repairActionTitle: String {
        if repairPhase != nil { return "处理中…" }
        if !isEnabled { return "启用电池管理" }
        if daemonStatus == .requiresApproval { return "前往系统设置" }
        if versionMismatch && !recoveryBlocked { return "安全更新后台" }
        if needsSystemChargeManagement { return "重新检查接口" }
        return backendReady && lastError == nil ? "检查状态" : "检查并修复"
    }
    private var diagnosticSummary: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "未知"
        return """
        App build: \(build)
        状态：\(diagnosisTitle)
        授权：\(permissionSummary)；连接：\(connectionSummary)；版本：\(versionSummary)
        预期 hash：\(expectedCodeHash ?? "未知")
        最近响应 hash：\(peerCodeHash ?? "未知")
        最近响应时间：\(lastBackendResponse?.ISO8601Format() ?? "尚无响应")
        最近手动检查发起时间：\(lastManualCheck?.ISO8601Format() ?? "本次启动尚未手动检查")
        错误：\(lastError ?? "无")
        系统限充：\(systemChargeLimitBackend)；设置回读：\(systemLimitReadback.map(String.init) ?? "未知")；策略观测：\(systemPolicyLimit.map(String.init) ?? "未知")；支持档位：\(systemChargeLimits)
        警告：\(warning ?? "无")
        系统启动：\(launchDiagnosis)
        只读接口诊断（发现键不代表已支持控制）：
        \(interfaceDiagnostics)
        电池动态：\(telemetryEvents.count)条，最近3000次采样；约每30秒及打开菜单时采样，休眠/退出期间不采样。连接事件独立保留1000条。
        功率口径：PSTR/PDTR为独立传感器读数，不保证同步或相等；电池功率由电压×电流计算，菜单电脑功率可能为推算。零电流不证明采样间隔内未放电。
        最近电池采样：\(telemetryEvents.first ?? "尚无采样")

        """
    }
    func makeDiagnosticSnapshot() -> BatteryDiagnosticSnapshot {
        BatteryDiagnosticSnapshot(generatedAt: Date(), summary: diagnosticSummary, events: allDiagnosticEvents)
    }
    var diagnosticReport: String { makeDiagnosticSnapshot().report }
    func copyDiagnosticReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport, forType: .string)
    }
    func checkAndRepair() {
        guard !working, repairPhase == nil else { return }
        lastManualCheck = Date()
        if !isEnabled { isEnabled = true; return }
        if daemonStatus != .enabled { authorize(); return }
        if versionMismatch && !recoveryBlocked { replaceBackend(); return }
        record("用户检查后台：重建连接并验证，不强制恢复或替换")
        connection?.invalidate(); connection = nil; verifiedConnection = false
        suspendedAfterFailure = false; consecutiveTransportFailures = 0
        replacementAttempted = false
        launchRepairAttempted = false
        repairPhase = "正在检查后台连接"; performingUserAction = true
        send({ proxy, reply in proxy.status(withReply: reply) }) { [weak self] success in
            guard let self else { return }
            self.repairPhase = nil; self.performingUserAction = false
            if success { self.recoveryBlocked = false; self.refresh() }
        }
    }

    /// Only called after the UI's explicit destructive-action confirmation.
    func repairWithAdministratorApproval(confirmed: Bool = false) {
        guard confirmed else {
            BatteryHelperSetupWindow.show(action: .repair)
            return
        }
        guard offersPrivilegedRepair, !working, !performingUserAction, repairPhase == nil else { return }
        guard BatteryControlIdentifiers.embeddedHelperMatchesSigner() else {
            lastError = "安装包内后台与 App 的签名不一致或签名无效，请重新签名安装。"
            record(lastError!); return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(BatteryControlIdentifiers.helperID)").path
        let quotedHelper = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let repairID = UUID(); requestID = repairID
        connection?.invalidate(); connection = nil; verifiedConnection = false; backendReady = false
        suspendedAfterFailure = true; working = true; performingUserAction = true
        repairPhase = "等待管理员授权与安全检查"
        record("用户确认管理员修复；需持独占锁，并确认硬件automatic，或接口未适配且安全恢复记录不存在，才停止本应用电池服务")
        AdminShell.runWithResult(quotedHelper + " --retire-for-registration-repair",
                                prompt: "修复 Vorssaint 电池后台。将检查充电安全状态，停止旧服务并重新注册。") { [weak self] status, output in
            guard let self, self.requestID == repairID else { return }
            self.record("管理员维护返回 status=\(status)：\(output)")
            guard status == 0, output.contains("BATTERY_MAINTENANCE_RETIRED=1") else {
                self.working = false; self.performingUserAction = false; self.repairPhase = nil
                self.lastError = "强制修复未完成（授权取消、超时或安全检查未通过）：\(output.isEmpty ? "请重新检查诊断报告" : String(output.prefix(500)))"
                return
            }
            self.repairPhase = "正在更新后台注册"
            if Self.daemon.status == .notRegistered || Self.daemon.status == .notFound {
                self.record("管理员维护已确认安全退出，旧注册不存在；直接注册当前内嵌助手")
                self.registerReplacement(repairID, attempt: 0)
                return
            }
            Self.daemon.unregister { error in
                DispatchQueue.main.async {
                    guard self.requestID == repairID else { return }
                    if let error {
                        self.working = false; self.performingUserAction = false; self.repairPhase = nil
                        self.lastError = "旧服务已停止，但注册清理失败：\(error.localizedDescription)。请重新检查。"
                        self.record(self.lastError!); return
                    }
                    self.record("管理员维护完成，旧注册已清理；开始注册新版，等待握手验证")
                    self.registerReplacement(repairID, attempt: 0)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.requestID == repairID, self.repairPhase == "正在更新后台注册" else { return }
                self.requestID = UUID(); self.working = false; self.performingUserAction = false; self.repairPhase = nil
                self.lastError = "注册更新未在期限内确认，结果未知，请重新检查。"
                self.record(self.lastError!)
            }
        }
    }
    /// Only the failed-to-spawn/no-PID case can bypass an impossible XPC ack.
    /// Never delete the journal or force-kill a live helper.
    private func diagnoseFailedLaunch() {
        guard isEnabled, !working, !launchRepairAttempted else { return }
        launchRepairAttempted = true
        suspendedAfterFailure = true
        working = true; performingUserAction = true
        repairPhase = "正在检查后台启动状态"
        let recoveryID = UUID(); requestID = recoveryID
        refreshQueue.async { [weak self] in
            let diagnosis = BatteryLaunchDiagnosis.inspect()
            let matchingSigner = diagnosis.processID.flatMap { BatteryControlIdentifiers.runningPeerMatchesSigner(pid: $0) }
            let automatic = diagnosis.failedWithoutProcess
                && (try? BatteryControlHardware(validating: SMCClient()).state()) == .automatic
            // Recheck after the hardware read: unknown/running states fail closed.
            let confirmed = automatic ? BatteryLaunchDiagnosis.inspect() : diagnosis
            DispatchQueue.main.async {
                guard let self, self.requestID == recoveryID else { return }
                self.launchDiagnosis = confirmed.summary
                self.signingMismatch = matchingSigner == false
                self.offersPrivilegedRepair = confirmed.readable
                self.record("运行中后台签名校验：\(matchingSigner.map { $0 ? "匹配" : "不一致" } ?? "未知")")
                self.record(confirmed.summary)
                guard automatic, confirmed.failedWithoutProcess, self.isEnabled else {
                    self.working = false; self.performingUserAction = false; self.repairPhase = nil
                    self.lastError = self.signingMismatch
                        ? "签名身份不一致，无法通过 XPC 更新。请用原证书重新安装，或选择管理员强制修复。"
                        : "后台连接失败。\(confirmed.summary)。未满足自动恢复条件；可查看诊断或使用管理员强制修复。"
                    return
                }
                self.record("后台启动失败且无 PID；充电及电源输入已回读为 automatic。保留恢复记录，重建注册。")
                self.repairPhase = "正在重建后台注册"
                self.connection?.invalidate(); self.connection = nil; self.verifiedConnection = false
                Self.daemon.unregister { error in
                    DispatchQueue.main.async {
                        guard self.requestID == recoveryID else { return }
                        if let error {
                            self.working = false; self.performingUserAction = false; self.repairPhase = nil
                            self.lastError = "后台注销失败：\(error.localizedDescription)"
                            self.record(self.lastError!); return
                        }
                        self.record("失效注册已注销；等待新版注册及握手，不视为已修复")
                        self.registerReplacement(recoveryID, attempt: 0)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                    guard let self, self.requestID == recoveryID, self.repairPhase == "正在重建后台注册" else { return }
                    self.requestID = UUID()
                    self.working = false; self.performingUserAction = false; self.repairPhase = nil
                    self.lastError = "系统未在期限内确认注销；操作结果未知，请重新检查"
                    self.record(self.lastError!)
                }
            }
        }
    }
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.batteryManagementEnabled)
            suspendedAfterFailure = false
            if !isEnabled { disconnect(); updateAccess(); return }
            refresh()
        }
    }
    @Published var chargeLimit: Int {
        didSet {
            guard oldValue != chargeLimit else { return }
            UserDefaults.standard.set(min(100, max(50, chargeLimit)), forKey: DefaultsKey.batteryManagementLimit)
            // Defaults notification is debounced; never recursively assign a slider property.
        }
    }
    private let refreshQueue = DispatchQueue(label: "com.vorssaint.battery.refresh", qos: .utility)
    private var refreshInFlight = false
    private var sleepProtectionSuspended = false

    func prepareForSystemSleep(attempt: Int = 0, completion: @escaping (Bool) -> Void) {
        sleepProtectionSuspended = true
        guard daemonStatus == .enabled || connection != nil else { completion(true); return }
        if working, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.sleepProtectionSuspended else { completion(false); return }
                self.prepareForSystemSleep(attempt: attempt + 1, completion: completion)
            }
            return
        }
        guard !working, backendReady else { completion(false); return }
        let configuration = currentConfiguration()
        send({ proxy, reply in
            proxy.update((try? JSONEncoder().encode(configuration)) ?? Data(), withReply: reply)
        }, completion: completion)
    }

    func resumeSleepProtection() {
        sleepProtectionSuspended = false
        refresh()
    }
    private var refreshGeneration = UUID()
    private var daemonStatus: SMAppService.Status = .notRegistered
    private var lastPreferences = NSDictionary()
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var observers: [AnyCancellable] = []
    private var requestID = UUID()
    private var suspendedAfterFailure = false
    private var replacementAttempted = false
    private var consecutiveTransportFailures = 0
    private var verifiedConnection = false
    private static let connectionLog = Logger(subsystem: BatteryControlIdentifiers.appID, category: "BatteryConnection")
    private var startupRegistrationAttempted = false
    private lazy var expectedCodeHash = BatteryControlIdentifiers.embeddedCodeHash()
    private static var daemon: SMAppService { .daemon(plistName: BatteryControlIdentifiers.plistName) }

    private init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: DefaultsKey.batteryManagementEnabled)
        chargeLimit = min(100, max(50, d.object(forKey: DefaultsKey.batteryManagementLimit) as? Int ?? 80))
        lastPreferences = refreshPreferences()
        record("App 启动 pid=\(ProcessInfo.processInfo.processIdentifier) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "未知")")
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let preferences = self.refreshPreferences()
                guard preferences != self.lastPreferences else { return }
                self.lastPreferences = preferences
                self.refresh()
            }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.record("系统唤醒；休眠期间无连续采样，重新确认后台与电池状态")
                BatteryPanelModel.shared.sample()
                self?.refresh()
            }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.record("系统即将睡眠；此事件不代表后台已执行睡眠充电策略")
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var statusText: String {
        if systemChargeLimitBackend {
            if let lastError { return lastError }
            if !isEnabled || !systemLimitConsent { return "系统限充尚未接管" }
            let setting = systemLimitReadback.map { "\($0)%" } ?? "待确认"
            let observed = systemPolicyLimit.map { "\($0)%" } ?? "未知"
            return "系统上限回读：\(setting) · 策略观测：\(observed)"
        }
        if needsSystemChargeManagement { return "App充电上限未生效，请使用系统电池设置" }
        if let lastError { return lastError }
        if !backendReady { return accessText }
        if thermalPause { return "温度保护暂停中（降温 3°C 后恢复）" }
        switch mode {
        case .automatic: return "系统自动充电"
        case .limited: return "充电保护中 · 上限 \(effectiveLimit)%"
        case .forceCharge: return "临时充至 100%，完成后恢复上限"
        case .inhibiting: return "已暂停充电"
        case .discharging: return "使用电池运行至 \(effectiveLimit)%"
        case .unavailable: return "充电后台不可用"
        }
    }

    func authorize(confirmed: Bool = false) {
        guard confirmed else {
            BatteryHelperSetupWindow.show(action: .install)
            return
        }
        record("请求注册/授权电池后台")
        suspendedAfterFailure = false
        consecutiveTransportFailures = 0
        do {
            if Self.daemon.status == .notRegistered || Self.daemon.status == .notFound {
                guard helperIsEmbedded else { lastError = "安装包缺少电池后台，请重新安装开发版"; return }
                UserDefaults.standard.set(true, forKey: "batteryManagement.helperRegistrationAttempted")
                try Self.daemon.register()
            }
            if Self.daemon.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            refresh()
        } catch { lastError = "后台注册失败：\(error.localizedDescription)"; record(lastError!); updateAccess() }
    }

    /// Ignore UI-only and unrelated defaults changes. Window/scroll state
    /// must not trigger hardware and ServiceManagement queries.
    private func refreshPreferences() -> NSDictionary {
        let defaults = UserDefaults.standard
        let keys = [DefaultsKey.batteryManagementEnabled, DefaultsKey.batteryManagementLimit,
                    DefaultsKey.batteryManagementResumeMargin, DefaultsKey.batteryManagementSleepPolicy,
                    DefaultsKey.batteryManagementTemperatureProtection, DefaultsKey.batteryManagementTemperatureLimit,
                    "batteryManagement.dischargeAboveLimit", "batteryManagement.preventSleepDischarging",
                    "batteryManagement.preventSleepCharging", "batteryManagement.greenLED", "batteryManagement.blinkLED",
                    "batteryManagement.automationEnabled", "batteryManagement.rules.v1", "batteryManagement.allowSystemChargeLimit"]
        var values = keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        values["featureAvailable"] = AppFeature.batteryManagement.isAvailable
        return values as NSDictionary
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let generation = refreshGeneration
        refreshQueue.async { [weak self] in
            // SMAppService.status performs synchronous XPC. Query it once,
            // off the main thread, along with the power-source snapshot.
            let status = Self.daemon.status
            let battery = SystemInfo.batterySnapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard self.refreshGeneration == generation else { return }
                if self.daemonStatus != status { self.record("注册状态变化 \(self.daemonStatus.rawValue) → \(status.rawValue)") }
                self.daemonStatus = status
                self.snapshot = battery
                self.updateAccess()
                let configuration = self.currentConfiguration()
                guard AppFeature.batteryManagement.isAvailable else {
                    if self.connection != nil { self.disconnect() }
                    return
                }
                if status == .notRegistered, self.isEnabled, !self.startupRegistrationAttempted {
                    self.startupRegistrationAttempted = true
                    self.authorize()
                    return
                }
                guard status == .enabled, !self.working, !self.suspendedAfterFailure else { return }
                self.send { proxy, reply in
                    proxy.update((try? JSONEncoder().encode(configuration)) ?? Data(), withReply: reply)
                }
            }
        }
    }
    func retry() {
        record("用户请求重新连接/恢复充电")
        guard !working, Self.daemon.status == .enabled else { updateAccess(); return }
        performingUserAction = true
        suspendedAfterFailure = false
        consecutiveTransportFailures = 0
        send({ proxy, reply in proxy.restore(withReply: reply) }) { [weak self] success in
            self?.performingUserAction = false
            if success { self?.refresh() }
        }
    }
    func forceCharge() { perform(.full) }
    func inhibitCharging() { perform(.pause) }
    func forceDischarge() { perform(.discharge) }
    func restoreAutomatic() { perform(.automatic) }
    func takeOver() {
        guard backendReady, needsTakeover, !working else { return }
        performingUserAction = true
        suspendedAfterFailure = false
        let configuration = currentConfiguration()
        send({ proxy, reply in proxy.update((try? JSONEncoder().encode(configuration)) ?? Data(), withReply: reply) }) { [weak self] success in
            guard let self else { return }
            guard self.backendReady, success || self.needsTakeover else {
                self.performingUserAction = false; return
            }
            self.send({ proxy, reply in proxy.command("takeover", withReply: reply) }) { [weak self] _ in
                self?.performingUserAction = false
            }
        }
    }

    /// Explicit reinstall is available even when versions already match.
    /// It preserves preferences and uses the same safe retirement handshake.
    func reinstallBackend(confirmed: Bool = false) {
        guard confirmed else {
            BatteryHelperSetupWindow.show(action: .reinstall)
            return
        }
        guard !working, !performingUserAction, repairPhase == nil else { return }
        guard helperIsEmbedded, BatteryControlIdentifiers.embeddedHelperMatchesSigner() else {
            lastError = "无法重新安装：当前 App 内的充电控制助手缺失或签名不一致。请先重新安装完整 App。"
            record(lastError!); return
        }
        record("用户确认重新安装充电控制助手；保留电池配置与日志，同版本也重新注册；不删除恢复记录")
        if Self.daemon.status == .enabled {
            replaceBackend(confirmed: true)
        } else {
            record("后台未运行或等待批准，转入当前内嵌助手注册/授权")
            authorize(confirmed: true)
        }
    }

    /// Retire the authenticated old daemon only after its recovery completes.
    /// SMAppService retains the user's approval when possible, otherwise the
    /// normal system approval UI remains necessary.
    func replaceBackend(confirmed: Bool = false) {
        guard confirmed else {
            BatteryHelperSetupWindow.show(action: .update)
            return
        }
        record("请求安全更新后台；等待旧后台确认恢复")
        guard !working else { record("安全更新未开始：已有请求正在执行"); return }
        guard Self.daemon.status == .enabled else { record("安全更新未开始：后台未启用"); return }
        guard let requirement = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.helperID) else {
            record("安全更新未开始：无法生成签名要求"); return
        }
        replacementAttempted = true
        repairPhase = "正在等待旧后台恢复充电"
        recoveryBlocked = false
        performingUserAction = true
        suspendedAfterFailure = true
        working = true
        let upgradeID = UUID(); requestID = upgradeID
        let transport = NSXPCConnection(machServiceName: BatteryControlIdentifiers.helperID, options: .privileged)
        transport.remoteObjectInterface = NSXPCInterface(with: BatteryControlXPCProtocol.self)
        transport.setCodeSigningRequirement(requirement)
        transport.activate()
        var replyHandled = false // Accessed only on the main queue.
        let finish: (Data?) -> Void = { [weak self] data in
            DispatchQueue.main.async {
                guard !replyHandled else { return }
                replyHandled = true
                guard let self, self.working, self.requestID == upgradeID else { transport.invalidate(); return }
                self.working = false
                transport.invalidate()
                self.record("安全更新 \(upgradeID)：恢复响应 bytes=\(data?.count ?? 0)")
                guard let data, let result = try? JSONDecoder().decode(BatteryControlResponse.self, from: data),
                      !result.active, result.error == nil else {
                    self.performingUserAction = false
                    self.repairPhase = nil
                    self.recoveryBlocked = true
                    self.offersPrivilegedRepair = true
                    self.lastError = "旧电池后台未确认恢复，暂未更新；请先恢复自动充电后重试"
                    self.record(self.lastError!)
                    return
                }
                self.record("安全更新 \(upgradeID)：恢复确认成功，开始注销")
                self.repairPhase = "正在更新电池后台"
                self.connection?.invalidate(); self.connection = nil
                self.verifiedConnection = false; self.backendReady = false
                self.working = true
                // The synchronous unregister returns before launchd reaps the
                // old job. Re-register only after the completion callback.
                Self.daemon.unregister { error in
                    DispatchQueue.main.async {
                        guard self.requestID == upgradeID else { return }
                        self.working = false
                        self.performingUserAction = false
                        if let error {
                            self.repairPhase = nil
                            self.record("安全更新注销失败：\((error as NSError).domain)/\((error as NSError).code) \(error.localizedDescription)")
                            self.lastError = "电池后台更新失败，请重新授权：\(error.localizedDescription)"
                            self.offersPrivilegedRepair = true
                            self.updateAccess()
                        } else {
                            self.record("安全更新注销完成，等待重新注册")
                            self.registerReplacement(upgradeID, attempt: 0)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, self.requestID == upgradeID,
                          self.repairPhase == "正在更新电池后台" else { return }
                    self.requestID = UUID()
                    self.working = false; self.performingUserAction = false; self.repairPhase = nil
                    self.lastError = "助手注销未在期限内确认；未强制重新注册，请检查状态后重试。"
                    self.offersPrivilegedRepair = true
                    self.record(self.lastError!)
                }
            }
        }
        guard let proxy = transport.remoteObjectProxyWithErrorHandler({ [weak self] error in
            DispatchQueue.main.async { self?.record("安全更新 \(upgradeID) XPC 错误：\((error as NSError).domain)/\((error as NSError).code) \(error.localizedDescription)") }
            finish(nil)
        }) as? BatteryControlXPCProtocol else { record("安全更新无法创建代理"); finish(nil); return }
        proxy.prepareForRemoval { finish($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard !replyHandled else { return }
            self?.record("安全更新 \(upgradeID)：等待恢复确认超时（8 秒）")
            finish(nil)
        }
    }

    private func registerReplacement(_ upgradeID: UUID, attempt: Int) {
        record("更新注册 attempt=\(attempt + 1)")
        repairPhase = "正在注册充电控制助手"
        working = true
        performingUserAction = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 2 : 5)) { [weak self] in
            guard let self, self.requestID == upgradeID else { return }
            do {
                try Self.daemon.register()
                self.record("安全更新注册成功 status=\(Self.daemon.status.rawValue)；等待握手验证")
                self.working = false
                self.performingUserAction = false
                self.lastError = nil
                self.repairPhase = nil
                self.suspendedAfterFailure = false
                self.backendReady = false
                self.refresh()
            } catch {
                self.record("安全更新注册失败：\((error as NSError).domain)/\((error as NSError).code) \(error.localizedDescription)")
                if attempt < 2, (Self.daemon.status == .notRegistered || Self.daemon.status == .notFound) {
                    self.registerReplacement(upgradeID, attempt: attempt + 1)
                } else {
                    self.working = false
                    self.performingUserAction = false
                    self.repairPhase = nil
                    self.lastError = "电池后台更新后尚未连接，请重新授权：\(error.localizedDescription)"
                    self.refresh()
                }
            }
        }
    }

    private func perform(_ command: BatteryCommand) {
        record("用户充电指令=\(command.rawValue)；请求不代表硬件已执行，需查看后续后台响应")
        guard !working else { record("指令\(command.rawValue)未发送：已有后台请求执行中"); return }
        guard Self.daemon.status == .enabled else {
            lastError = "请先授权独立电池后台"
            record("指令\(command.rawValue)未发送：后台未授权/启用")
            return
        }
        suspendedAfterFailure = false
        performingUserAction = true
        let configuration = currentConfiguration()
        send({ proxy, reply in proxy.update((try? JSONEncoder().encode(configuration)) ?? Data(), withReply: reply) }) { [weak self] success in
            guard let self else { return }
            guard success else {
                self.record("指令\(command.rawValue)未发送：前置策略同步失败")
                self.performingUserAction = false; return
            }
            self.send({ proxy, reply in proxy.command(command.rawValue, withReply: reply) }) { [weak self] _ in
                self?.performingUserAction = false
            }
        }
    }

    private func disconnect() {
        // Invalidating an in-flight request triggers restoration in the helper.
        requestID = UUID()
        refreshGeneration = UUID()
        connection?.invalidate(); connection = nil
        working = false; performingUserAction = false; backendReady = false; mode = .automatic
        verifiedConnection = false
        repairPhase = nil
    }
    func prepareForTermination() { suspendedAfterFailure = true; timer?.invalidate(); disconnect() }

    /// Called from the uninstall worker/CLI. Never remove the recovery daemon
    /// until it has confirmed all hardware was restored.
    static func restoreAndUnregisterForRemoval() -> Bool {
        let daemon = Self.daemon
        if daemon.status == .notRegistered { return true }
        if daemon.status == .notFound,
           !UserDefaults.standard.bool(forKey: "batteryManagement.helperRegistrationAttempted") { return true }
        if daemon.status == .enabled {
            guard let requirement = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.helperID) else { return false }
            let connection = NSXPCConnection(machServiceName: BatteryControlIdentifiers.helperID, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: BatteryControlXPCProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            connection.activate()
            defer { connection.invalidate() }
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var restored = false
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in semaphore.signal() }) as? BatteryControlXPCProtocol else { return false }
            proxy.prepareForRemoval { data in
                if let result = try? JSONDecoder().decode(BatteryControlResponse.self, from: data) {
                    lock.lock(); restored = !result.active && result.error == nil; lock.unlock()
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 8) == .success else { return false }
            lock.lock(); let success = restored; lock.unlock()
            guard success else { return false }
        } else {
            // Revoked approval can hide a pending recovery journal. Require
            // re-approval and a confirmed restore, never delete blindly.
            return false
        }
        do { try daemon.unregister(); return daemon.status == .notRegistered }
        catch { return false }
    }

    private func updateAccess() {
        switch daemonStatus {
        case .enabled: accessText = backendName.map { "电池后台已连接 · \($0)" } ?? "后台已注册，连接后确认状态"
        case .requiresApproval: accessText = "请在系统设置 → 登录项与扩展中允许电池后台"
        case .notRegistered: accessText = "电池后台未授权"
        case .notFound: accessText = helperIsEmbedded ? "电池后台尚未注册，请点击授权" : "安装包缺少电池后台，请重新安装开发版"
        default: accessText = "电池后台不可用，请使用已签名的安装版"
        }
        if daemonStatus != .enabled { backendReady = false; mode = .unavailable }
    }
    private var helperIsEmbedded: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(BatteryControlIdentifiers.plistName)").path)
        && FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/\(BatteryControlIdentifiers.helperID)").path)
    }

    private func currentConfiguration() -> BatteryControlConfiguration {
        let d = UserDefaults.standard
        var c = BatteryControlConfiguration()
        c.enabled = isEnabled && AppFeature.batteryManagement.isAvailable
        c.allowSystemChargeLimit = systemLimitConsent
        c.limit = min(100, max(50, chargeLimit))
        c.resumeMargin = min(10, max(3, d.object(forKey: DefaultsKey.batteryManagementResumeMargin) as? Int ?? 5))
        c.sleepPolicy = d.string(forKey: DefaultsKey.batteryManagementSleepPolicy) == "automatic" ? "automatic" : "limit"
        c.protectTemperature = d.object(forKey: DefaultsKey.batteryManagementTemperatureProtection) as? Bool ?? true
        c.temperatureLimit = min(45, max(35, d.object(forKey: DefaultsKey.batteryManagementTemperatureLimit) as? Int ?? 40))
        c.dischargeAboveLimit = d.bool(forKey: "batteryManagement.dischargeAboveLimit")
        c.preventSleepDischarging = !sleepProtectionSuspended && d.bool(forKey: "batteryManagement.preventSleepDischarging")
        c.preventSleepCharging = !sleepProtectionSuspended && d.bool(forKey: "batteryManagement.preventSleepCharging")
        c.greenLED = d.bool(forKey: "batteryManagement.greenLED")
        c.blinkLED = d.bool(forKey: "batteryManagement.blinkLED")
        let automation = BatteryAutomationService.shared
        automation.updateLocationSampling()
        if c.enabled, let rule = automation.matchingRule() { c.limit = rule.limit; activeRule = rule.name }
        else { activeRule = nil }
        effectiveLimit = c.limit
        // Compare canonical JSON so dictionary key order cannot flood the log.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(c), let canonical = String(data: data, encoding: .utf8) {
            if lastConfigurationLog != canonical {
                lastConfigurationLog = canonical
                record("有效充电策略（准备同步，非执行确认）=\(canonical)；自动化规则命中=\(activeRule != nil)")
            }
        }
        return c
    }

    private func send(_ operation: @escaping (BatteryControlXPCProtocol, @escaping (Data) -> Void) -> Void,
                      completion: ((Bool) -> Void)? = nil) {
        if connection == nil {
            record("创建 XPC 连接；目标=\(BatteryControlIdentifiers.helperID)")
            verifiedConnection = false
            guard let requirement = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.helperID) else {
                lastError = "后台需要证书签名；不接受临时签名版本"; completion?(false); return
            }
            let connection = NSXPCConnection(machServiceName: BatteryControlIdentifiers.helperID, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: BatteryControlXPCProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            connection.activate()
            self.connection = connection
        }
        let handshaking = !verifiedConnection
        let id = UUID(); requestID = id; working = true
        let started = ProcessInfo.processInfo.systemUptime
        record("请求 \(id) 开始 phase=\(handshaking ? "握手" : "控制/同步")")
        let finish: (Data?) -> Void = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.requestID == id, self.working else { return }
                self.working = false
                self.record("请求 \(id) 返回 elapsed=\(ProcessInfo.processInfo.systemUptime - started)s bytes=\(data?.count ?? 0)")
                guard let data, let result = try? JSONDecoder().decode(BatteryControlResponse.self, from: data), (1...2).contains(result.version) else {
                    self.consecutiveTransportFailures += 1
                    self.record("连接失败 count=\(self.consecutiveTransportFailures)；\(data == nil ? "传输错误或超时" : "响应解码/协议校验失败")")
                    self.backendReady = false
                    self.connection?.invalidate(); self.connection = nil
                    self.mode = .unavailable
                    completion?(false)
                    if self.consecutiveTransportFailures < 3, self.daemonStatus == .enabled {
                        self.lastError = "电池后台连接暂时中断，正在自动重连…"
                        self.suspendedAfterFailure = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            guard let self, !self.working, !self.suspendedAfterFailure else { return }
                            self.refresh()
                        }
                    } else {
                        self.lastError = "电池后台连续 3 次未响应，请检查并修复；原因尚未确认"
                        self.suspendedAfterFailure = true
                        self.diagnoseFailedLaunch()
                    }
                    return
                }
                self.consecutiveTransportFailures = 0
                self.peerCodeHash = result.codeHash
                self.lastBackendResponse = Date()
                if handshaking {
                    self.record("握手 protocol=\(result.version) actual=\(result.codeHash ?? "缺失") expected=\(self.expectedCodeHash ?? "缺失")")
                    guard let expected = self.expectedCodeHash else {
                        self.lastError = "无法验证安装包内的电池后台，请重新安装已签名版本"
                        self.suspendedAfterFailure = true
                        self.backendReady = false
                        completion?(false)
                        return
                    }
                    guard result.version == 2, result.codeHash == expected else {
                        self.versionMismatch = true
                        self.lastError = "电池后台版本与安装包不一致，请在更新窗口确认后继续"
                        self.backendReady = false
                        self.suspendedAfterFailure = true
                        completion?(false)
                        if !self.replacementAttempted { self.replaceBackend() }
                        return
                    }
                    self.verifiedConnection = true
                    self.versionMismatch = false
                    self.signingMismatch = false
                    self.offersPrivilegedRepair = false
                    self.send(operation, completion: completion)
                    return
                }
                guard result.version == 2 else {
                    self.backendReady = false; self.suspendedAfterFailure = true
                    self.lastError = "电池后台仍为旧版，需要安全更新"
                    completion?(false)
                    if !self.replacementAttempted { self.replaceBackend() }
                    return
                }
                self.backendReady = result.supported
                self.systemChargeLimitBackend = result.systemChargeLimitBackend == true
                self.systemChargeLimits = result.systemChargeLimits ?? []
                self.systemLimitReadback = result.systemLimitReadback
                self.systemPolicyLimit = result.systemPolicyLimit
                if self.systemChargeLimitBackend {
                    self.record("系统限充响应：setting=\(result.systemLimitReadback.map(String.init) ?? "未知") policy=\(result.systemPolicyLimit.map(String.init) ?? "未知") active=\(result.active)；回读不代表物理停充")
                }
                self.interfaceUnavailable = result.interfaceUnavailable == true
                if let diagnostics = result.interfaceDiagnostics, diagnostics != self.interfaceDiagnostics {
                    self.interfaceDiagnostics = diagnostics
                    self.record("只读接口探测：\(diagnostics)")
                }
                self.record("后台状态 request=\(id) command=\(result.command.rawValue) override=\(result.override.rawValue) active=\(result.active) overheated=\(result.overheated) backend=\(result.backendName ?? "未知") error=\(result.error ?? "无") warning=\(result.warning ?? "无")；后台响应不等于电池电流实测")
                self.backendName = result.backendName
                self.dischargeSupported = result.dischargeSupported == true
                self.needsTakeover = result.needsTakeover == true
                self.ledSupported = result.ledSupported
                self.lastError = result.error ?? (result.supported ? nil : "充电接口探测未成功，请重试或查看系统适配状态")
                self.updateAccess()
                self.warning = result.warning; self.thermalPause = result.overheated
                self.suspendedAfterFailure = self.lastError != nil
                self.mode = !result.supported ? .unavailable
                    : result.command == .discharge ? .discharging
                    : result.command == .pause ? .inhibiting
                    : result.override == .full ? .forceCharge
                    : result.active && self.isEnabled ? .limited : .automatic
                completion?(self.lastError == nil)
            }
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            DispatchQueue.main.async { [weak self] in self?.record("XPC 请求 \(id) error=\((error as NSError).domain)/\((error as NSError).code): \(error.localizedDescription)") }
            Self.connectionLog.error("XPC failure: \(error.localizedDescription, privacy: .public)")
            finish(nil)
        }) as? BatteryControlXPCProtocol else { finish(nil); return }
        if handshaking { proxy.status(withReply: { finish($0) }) }
        else { operation(proxy) { finish($0) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.requestID == id, self.working else { return }
            self.record("请求 \(id) 超时（8 秒）")
            finish(nil)
        }
    }
}
