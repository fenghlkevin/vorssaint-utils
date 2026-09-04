// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import ServiceManagement

/// Only the independent privileged helper writes charging keys.
final class BatteryManagementService: ObservableObject {
    static let shared = BatteryManagementService()
    enum Mode: String { case automatic, limited, forceCharge, inhibiting, discharging, unavailable }
    @Published private(set) var snapshot: BatteryInfo?
    @Published private(set) var mode: Mode = .automatic
    @Published private(set) var lastError: String?
    @Published private(set) var warning: String?
    @Published private(set) var accessText = "后台未授权"
    @Published private(set) var backendReady = false
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
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var observers: [AnyCancellable] = []
    private var requestID = UUID()
    private var suspendedAfterFailure = false
    private var replacementAttempted = false
    private var consecutiveTransportFailures = 0
    private static var daemon: SMAppService { .daemon(plistName: BatteryControlIdentifiers.plistName) }

    private init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: DefaultsKey.batteryManagementEnabled)
        chargeLimit = min(100, max(50, d.object(forKey: DefaultsKey.batteryManagementLimit) as? Int ?? 80))
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var statusText: String {
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

    func authorize() {
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
        } catch { lastError = "后台注册失败：\(error.localizedDescription)"; updateAccess() }
    }

    func refresh() {
        snapshot = SystemInfo.batterySnapshot()
        updateAccess()
        let configuration = currentConfiguration()
        guard AppFeature.batteryManagement.isAvailable else {
            if connection != nil { disconnect() }
            return
        }
        guard Self.daemon.status == .enabled, !working, !suspendedAfterFailure else { return }
        send { proxy, reply in proxy.update((try? JSONEncoder().encode(configuration)) ?? Data(), withReply: reply) }
    }
    func retry() {
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

    /// Retire the authenticated old daemon only after its recovery completes.
    /// SMAppService retains the user's approval when possible, otherwise the
    /// normal system approval UI remains necessary.
    func replaceBackend() {
        guard !working, Self.daemon.status == .enabled,
              let requirement = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.helperID) else { return }
        replacementAttempted = true
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
                guard let data, let result = try? JSONDecoder().decode(BatteryControlResponse.self, from: data),
                      !result.active, result.error == nil else {
                    self.performingUserAction = false
                    self.lastError = "旧电池后台未确认恢复，暂未更新；请先恢复自动充电后重试"
                    return
                }
                self.connection?.invalidate(); self.connection = nil
                self.working = true
                // The synchronous unregister returns before launchd reaps the
                // old job. Re-register only after the completion callback.
                Self.daemon.unregister { error in
                    DispatchQueue.main.async {
                        guard self.requestID == upgradeID else { return }
                        self.working = false
                        self.performingUserAction = false
                        do {
                            if let error { throw error }
                            try Self.daemon.register()
                            self.lastError = nil; self.suspendedAfterFailure = false
                            self.backendReady = false
                            if Self.daemon.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                            self.refresh()
                        } catch {
                            self.lastError = "电池后台更新失败，请重新授权：\(error.localizedDescription)"
                            self.updateAccess()
                        }
                    }
                }
            }
        }
        guard let proxy = transport.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? BatteryControlXPCProtocol else { finish(nil); return }
        proxy.prepareForRemoval { finish($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(nil) }
    }

    private func perform(_ command: BatteryCommand) {
        guard !working else { return }
        guard Self.daemon.status == .enabled else { lastError = "请先授权独立电池后台"; return }
        suspendedAfterFailure = false
        performingUserAction = true
        let configuration = currentConfiguration()
        send({ proxy, reply in proxy.update((try? JSONEncoder().encode(configuration)) ?? Data(), withReply: reply) }) { [weak self] success in
            guard let self else { return }
            guard success else { self.performingUserAction = false; return }
            self.send({ proxy, reply in proxy.command(command.rawValue, withReply: reply) }) { [weak self] _ in
                self?.performingUserAction = false
            }
        }
    }

    private func disconnect() {
        // Invalidating an in-flight request triggers restoration in the helper.
        requestID = UUID()
        connection?.invalidate(); connection = nil
        working = false; performingUserAction = false; backendReady = false; mode = .automatic
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
        switch Self.daemon.status {
        case .enabled: accessText = backendName.map { "电池后台已连接 · \($0)" } ?? "后台已注册，连接后确认状态"
        case .requiresApproval: accessText = "请在系统设置 → 登录项与扩展中允许电池后台"
        case .notRegistered: accessText = "电池后台未授权"
        case .notFound: accessText = helperIsEmbedded ? "电池后台尚未注册，请点击授权" : "安装包缺少电池后台，请重新安装开发版"
        default: accessText = "电池后台不可用，请使用已签名的安装版"
        }
        if Self.daemon.status != .enabled { backendReady = false; mode = .unavailable }
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
        c.limit = min(100, max(50, chargeLimit))
        c.resumeMargin = min(10, max(3, d.object(forKey: DefaultsKey.batteryManagementResumeMargin) as? Int ?? 5))
        c.sleepPolicy = d.string(forKey: DefaultsKey.batteryManagementSleepPolicy) == "automatic" ? "automatic" : "limit"
        c.protectTemperature = d.object(forKey: DefaultsKey.batteryManagementTemperatureProtection) as? Bool ?? true
        c.temperatureLimit = min(45, max(35, d.object(forKey: DefaultsKey.batteryManagementTemperatureLimit) as? Int ?? 40))
        c.dischargeAboveLimit = d.bool(forKey: "batteryManagement.dischargeAboveLimit")
        c.preventSleepDischarging = d.bool(forKey: "batteryManagement.preventSleepDischarging")
        c.preventSleepCharging = d.bool(forKey: "batteryManagement.preventSleepCharging")
        c.greenLED = d.bool(forKey: "batteryManagement.greenLED")
        c.blinkLED = d.bool(forKey: "batteryManagement.blinkLED")
        let automation = BatteryAutomationService.shared
        automation.updateLocationSampling()
        if c.enabled, let rule = automation.matchingRule() { c.limit = rule.limit; activeRule = rule.name }
        else { activeRule = nil }
        effectiveLimit = c.limit
        return c
    }

    private func send(_ operation: @escaping (BatteryControlXPCProtocol, @escaping (Data) -> Void) -> Void,
                      completion: ((Bool) -> Void)? = nil) {
        guard let requirement = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.helperID) else {
            lastError = "后台需要证书签名；不接受临时签名版本"; completion?(false); return
        }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: BatteryControlIdentifiers.helperID, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: BatteryControlXPCProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            connection.activate()
            self.connection = connection
        }
        let id = UUID(); requestID = id; working = true
        let finish: (Data?) -> Void = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.requestID == id, self.working else { return }
                self.working = false
                guard let data, let result = try? JSONDecoder().decode(BatteryControlResponse.self, from: data), (1...2).contains(result.version) else {
                    self.consecutiveTransportFailures += 1
                    self.backendReady = false
                    self.connection?.invalidate(); self.connection = nil
                    self.mode = .unavailable
                    completion?(false)
                    if self.consecutiveTransportFailures < 3, Self.daemon.status == .enabled {
                        self.lastError = "电池后台连接暂时中断，正在自动重连…"
                        self.suspendedAfterFailure = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            guard let self, !self.working, !self.suspendedAfterFailure else { return }
                            self.refresh()
                        }
                    } else {
                        self.lastError = "电池后台连续 3 次未响应，请点击重新连接 / 重试"
                        self.suspendedAfterFailure = true
                    }
                    return
                }
                self.consecutiveTransportFailures = 0
                guard result.version == 2 else {
                    self.backendReady = false; self.suspendedAfterFailure = true
                    self.lastError = "电池后台仍为旧版，需要安全更新"
                    completion?(false)
                    if !self.replacementAttempted { self.replaceBackend() }
                    return
                }
                self.backendReady = result.supported
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
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? BatteryControlXPCProtocol else { finish(nil); return }
        operation(proxy) { finish($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(nil) }
    }
}
