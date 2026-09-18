// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import Security
import OSLog

private let diagnosticLog = Logger(subsystem: BatteryControlIdentifiers.helperID, category: "BatteryBackend")

/// Shared between release/development helpers. Journal precedes ALL writes;
/// launchd restarts a crashed helper and recovery retries until readback passes.
private final class BatteryOwnership {
    private let journalDirectory = "/Library/Application Support/VorssaintBatteryControl"
    private let marker = "/Library/Application Support/VorssaintBatteryControl/active"
    private var descriptor: Int32 = -1
    var held: Bool { descriptor >= 0 }
    /// Unlike `marked`, this fails closed on invalid metadata or access errors.
    var recoveryRecordAbsent: Bool {
        guard held, secureJournalDirectory(create: false) else { return false }
        guard !BatterySystemLimitFileJournal().mayExist else { return false }
        var s = stat()
        return lstat(marker, &s) != 0 && errno == ENOENT
    }
    var marked: Bool {
        guard secureJournalDirectory(create: false) else { return false }
        var s = stat()
        return lstat(marker, &s) == 0 && valid(s)
    }
    private func valid(_ s: stat) -> Bool {
        s.st_uid == 0 && (s.st_mode & S_IFMT) == S_IFREG && s.st_nlink == 1 && (s.st_mode & 0o077) == 0
    }
    private func secureJournalDirectory(create: Bool) -> Bool {
        if create { _ = mkdir(journalDirectory, mode_t(0o700)) }
        var s = stat()
        return lstat(journalDirectory, &s) == 0 && s.st_uid == 0
            && (s.st_mode & S_IFMT) == S_IFDIR && (s.st_mode & 0o077) == 0
    }
    func acquire() -> Bool {
        if held { return true }
        let fd = Darwin.open("/var/run/vorssaint-battery-control.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { return false }
        var s = stat()
        guard fstat(fd, &s) == 0, valid(s), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); return false
        }
        descriptor = fd
        return true
    }
    func mark() -> Bool {
        guard held, secureJournalDirectory(create: true) else { return false }
        if marked { return true }
        let fd = Darwin.open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var s = stat()
        return fstat(fd, &s) == 0 && valid(s) && fsync(fd) == 0
    }
    func clear() -> Bool { !marked || unlink(marker) == 0 }
    func release() {
        if held { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
    }
}

// All state and hardware operations run on the main run loop, including power
// notifications. XPC handlers dispatch here; there are no concurrent SMC writes.
private final class BatteryController {
    private let ownership = BatteryOwnership()
    private var hardware: BatteryControlHardware?
    private var systemClient: BatteryPowerUI?
    private var systemSession: BatterySystemLimitSession?
    private let systemJournal = BatterySystemLimitFileJournal()
    private var configuration = BatteryControlConfiguration()
    private var policy = BatteryControlPolicy()
    private var owner: UUID?
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var sleeping = false
    private var timer: Timer?
    private var idleSleepAssertion: IOPMAssertionID = 0
    private var systemSleepAssertion: IOPMAssertionID = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var powerConnection: io_connect_t = 0
    private var response = BatteryControlResponse()
    private var lastLED: UInt8 = 0
    private var recovering = false
    private var dischargeStarted: TimeInterval?
    private var latchedFailure: String?
    private var retiring = false

    init() {
        response.codeHash = BatteryControlIdentifiers.runningCodeHash
        probeHardware()
        if ownership.marked || systemJournal.mayExist, ownership.acquire() { recovering = true; _ = restore() }
        powerConnection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, type, argument in
            guard let context else { return }
            let controller = Unmanaged<BatteryController>.fromOpaque(context).takeUnretainedValue()
            controller.power(type, argument: argument)
        }, &notifier)
        if let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func status() -> Data {
        // A manual recheck must refresh failed discovery, not return a cached
        // startup failure. Never interfere with an owned/recovering controller.
        if hardware == nil && !ownership.held && !recovering {
            probeHardware()
            if systemSession != nil { latchedFailure = nil }
        }
        return response.encoded
    }

    private func probeHardware() {
        let smc = SMCClient()
        response.interfaceDiagnostics = ProcessInfo.processInfo.operatingSystemVersionString + "\n"
            + (smc?.batteryInterfaceDiagnostics() ?? "AppleSMC连接失败，未执行键查询")
            + "\n" + BatteryPowerUI.interfaceDiagnostics()
        response.interfaceUnavailable = false
        do {
            hardware = try BatteryControlHardware(validating: smc)
            response.error = nil
        } catch {
            hardware = nil; response.error = error.localizedDescription
            if let failure = error as? BatteryControlHardware.ProbeFailure {
                switch failure {
                case .missing, .layout: response.interfaceUnavailable = true
                default: break
                }
            }
        }
        response.supported = hardware != nil
        response.backendName = hardware?.backendName
        response.dischargeSupported = hardware?.dischargeSupported == true
        response.ledSupported = hardware?.ledSupported == true
        systemClient = nil; systemSession = nil
        response.systemChargeLimitBackend = false
        response.systemChargeLimits = nil
        if hardware == nil && response.interfaceUnavailable == true {
            do {
                let client = try BatteryPowerUI()
                systemClient = client
                systemSession = BatterySystemLimitSession(client: client, journal: systemJournal)
                response.systemChargeLimits = try client.availableLimits()
                response.systemLimitReadback = try client.read().limit
                response.systemPolicyLimit = BatteryPowerUI.policyLimit()
                response.systemChargeLimitBackend = true
                response.backendName = "PowerUI · 系统充电上限"
                response.supported = true; response.interfaceUnavailable = false; response.error = nil
            } catch {
                response.interfaceDiagnostics = (response.interfaceDiagnostics ?? "") + "\nPowerUI probe: " + error.localizedDescription
            }
        }
    }

    func update(_ data: Data, session: UUID) -> Data {
        diagnosticLog.notice("update begin session=\(session) bytes=\(data.count)")
        defer { diagnosticLog.notice("update end session=\(session)") }
        guard !retiring else { return failure("电池后台正在安全卸载") }
        guard data.count < 8192, let config = try? JSONDecoder().decode(BatteryControlConfiguration.self, from: data), config.isValid else {
            return failure("配置无效")
        }
        guard owner == nil || owner == session else { return failure("电池后台正由另一个客户端控制") }
        guard !recovering else { return failure("正在恢复系统充电，暂不能接管") }
        if let latchedFailure { return failure(latchedFailure) }
        configuration = config
        heartbeat = ProcessInfo.processInfo.systemUptime
        if systemClient != nil && config.allowSystemChargeLimit != true {
            if owner != nil { _ = restore() }
            response.warning = "系统限充需要确认：将修改系统充电上限；暂停充电、主动放电和自定义温控不适用于此接口"
            return response.encoded
        }
        if config.enabled || policy.override != .automatic {
            guard begin(session) else { return response.encoded }
            evaluate()
        } else if owner != nil { _ = restore() }
        return response.encoded
    }

    func command(_ name: String, session: UUID) -> Data {
        guard !retiring else { return failure("电池后台正在安全卸载") }
        let takingOver = name == "takeover"
        guard let command = takingOver ? .automatic : BatteryCommand(rawValue: name), owner == nil || owner == session else { return failure("命令无效或已有其他控制者") }
        if systemClient != nil && (command != .automatic || configuration.allowSystemChargeLimit != true || takingOver) {
            return failure("系统限充模式不提供暂停/强制充满/主动放电；请在设置中确认并调整系统上限")
        }
        if command == .discharge, hardware?.dischargeSupported != true {
            return failure("充电上限接口可用，但未识别安全的主动放电接口")
        }
        guard !recovering else { return failure("正在恢复系统充电") }
        guard begin(session, takingOver: takingOver) else { return response.encoded }
        policy.override = command
        heartbeat = ProcessInfo.processInfo.systemUptime
        evaluate()
        return response.encoded
    }

    private func begin(_ session: UUID, takingOver: Bool = false) -> Bool {
        if owner == session { return true }
        guard powerConnection != 0 else { _ = failure("无法注册睡眠保护，未接管充电"); return false }
        if systemSession != nil {
            guard configuration.allowSystemChargeLimit == true else { return false }
            guard ownership.acquire() else { _ = failure("另一个 Vorssaint 版本正在控制电池"); return false }
            if ownership.marked || systemJournal.mayExist { recovering = true; _ = restore(); return false }
            owner = session; response.active = false; response.needsTakeover = false
            return true
        }
        guard let hardware else { return false }
        guard ownership.acquire() else { _ = failure("另一个 Vorssaint 版本正在控制电池"); return false }
        if ownership.marked || systemJournal.mayExist { recovering = true; _ = restore(); return false }
        do {
            // Explicit takeover accepts only a recognized state, never an
            // unknown payload or a failed read. Journal still precedes writes.
            if takingOver { _ = try hardware.state() }
            else { try hardware.validateUncontrolled() }
        } catch BatteryControlHardware.Failure.otherController {
            ownership.release(); response.needsTakeover = true
            _ = failure("检测到已有充电限制，请退出其他充电工具后确认接管")
            return false
        } catch {
            ownership.release(); _ = failure("充电状态读取失败，尚未接管，请重试")
            return false
        }
        guard ownership.mark() else { ownership.release(); _ = failure("无法建立恢复记录，未修改充电状态"); return false }
        owner = session
        response.needsTakeover = false
        response.active = true
        return true
    }

    func disconnected(_ session: UUID) { if owner == session { _ = restore() } }

    func reset() {
        if restore() { latchedFailure = nil; probeHardware() }
    }
    func retire() { retiring = true; reset() }

    @discardableResult func restore() -> Bool {
        diagnosticLog.notice("restore begin")
        defer { diagnosticLog.notice("restore end recovering=\(self.recovering)") }
        releaseAssertion()
        guard ownership.held else { return true }
        do {
            if systemJournal.mayExist || (systemSession != nil && owner != nil) {
                if systemSession == nil {
                    let client = try BatteryPowerUI()
                    systemSession = BatterySystemLimitSession(client: client, journal: systemJournal)
                }
                guard let systemSession, try systemSession.restore() else { throw BatteryPowerUIError.unconfirmed }
                // A legacy SMC recovery marker must never be removed by PowerUI.
                guard !ownership.marked else { throw BatteryPowerUIError.journal }
                ownership.release(); owner = nil; recovering = false
                policy = BatteryControlPolicy(); response.active = false
                response.command = .automatic; response.override = .automatic
                response.overheated = false; response.error = nil; response.warning = nil
                response.systemLimitReadback = systemSession.confirmedLimit
                return true
            }
            if hardware == nil { probeHardware() }
            guard let hardware else { throw BatteryControlHardware.Failure.unsupported }
            let ledRestoreFailed = try hardware.restore()
            guard ownership.clear() else { throw BatteryControlHardware.Failure.readback }
            ownership.release()
            owner = nil
            recovering = false
            policy = BatteryControlPolicy()
            response.active = false
            response.command = .automatic
            response.override = .automatic
            response.overheated = false
            response.error = nil
            response.warning = ledRestoreFailed ? "系统充电已恢复，但 MagSafe 灯效未能复位" : nil
            lastLED = 0
            dischargeStarted = nil
            return true
        } catch {
            recovering = true
            response.error = "恢复系统充电失败；保留恢复记录，请勿卸载后台：\(error.localizedDescription)"
            return false
        }
    }

    private func tick() {
        if recovering { _ = restore(); return }
        guard owner != nil, !sleeping else { return }
        if ProcessInfo.processInfo.systemUptime - heartbeat > 90 { _ = restore(); return }
        evaluate()
    }

    private func evaluate() {
        diagnosticLog.info("evaluate begin")
        defer { diagnosticLog.info("evaluate end command=\(self.response.command.rawValue, privacy: .public)") }
        if let systemSession {
            releaseAssertion()
            // macOS keeps enforcing the last system limit during sleep. This
            // route does not claim the SMC sleep/thermal/discharge controls.
            if sleeping { return }
            do {
                let confirmed = try systemSession.apply(configuration.limit)
                response.systemLimitReadback = systemSession.confirmedLimit
                response.systemPolicyLimit = BatteryPowerUI.policyLimit()
                response.active = confirmed
                response.command = .automatic; response.override = .automatic; response.overheated = false
                response.error = nil
                response.warning = confirmed
                    ? "系统上限已回读 \(configuration.limit)%；不代表电池已停止充电。温控、睡眠和恢复阈值由 macOS 决定"
                    : "上限请求已发送，等待系统回读；尚未确认生效"
                diagnosticLog.notice("PowerUI target=\(self.configuration.limit) confirmed=\(confirmed) policy=\(self.response.systemPolicyLimit ?? -1)")
            } catch {
                let message = error.localizedDescription
                _ = restore()
                latchedFailure = message
                response.error = "系统限充未完成：\(message)；请检查并重试"
                response.active = false
            }
            return
        }
        guard let hardware, var input = BatteryControlHardware.input() else {
            let restored = restore()
            latchedFailure = "电池传感器不可用，已恢复系统充电；请检查后重试"
            if restored { response.error = latchedFailure }
            return
        }
        // ExternalConnected can change when we isolate AC. AC-W is the
        // physical cable state, so forced discharge must use it instead.
        let physicalPower = hardware.physicalPowerConnected()
        if let physicalPower { input.external = physicalPower }
        var target = policy.evaluate(input, config: configuration, sleeping: sleeping)
        let unavailableDischarge = target == .discharge && (!hardware.dischargeSupported || physicalPower == nil)
        if unavailableDischarge { target = .pause; policy.override = .automatic }
        let now = ProcessInfo.processInfo.systemUptime
        if target == .discharge {
            if dischargeStarted == nil { dischargeStarted = now }
            if now - (dischargeStarted ?? now) > 4 * 3600 {
                _ = restore()
                latchedFailure = "已达到 4 小时放电安全时限，停止本次控制；请手动重试"
                response.error = latchedFailure
                return
            }
        } else { dischargeStarted = nil }
        if input.percent <= 20, target == .discharge { target = .automatic }
        do {
            if try hardware.state() != target { try hardware.apply(target) }
            diagnosticLog.info("hardware applied target=\(target.rawValue, privacy: .public)")
            response.command = target
            response.override = policy.override
            response.overheated = policy.overheated
            response.error = nil
            response.warning = unavailableDischarge ? "主动放电接口或外接电源状态不可读，已改为暂停充电" : nil
            response.active = true
            let led: UInt8 = target == .pause && configuration.greenLED ? 3
                : target == .discharge && configuration.blinkLED ? 5 : 0
            if hardware.ledSupported, led != lastLED {
                do { try hardware.setLED(led); lastLED = led }
                catch { response.warning = "充电控制有效，但 MagSafe 灯效写入未通过验证" }
            }
            updateAssertion(input: input, command: target)
        } catch {
            let restored = restore()
            latchedFailure = "充电写入/回读失败，已恢复系统充电；请检查后重试"
            if restored { response.error = latchedFailure }
        }
    }

    private func updateAssertion(input: BatteryControlInput, command: BatteryCommand) {
        let protectingDischarge = !sleeping && input.external
            && command == .discharge && configuration.preventSleepDischarging
        let protectingCharge = !sleeping && input.external
            && command == .automatic && input.charging && !input.lidClosed
            && input.percent < (policy.override == .full ? 100 : configuration.limit)
            && configuration.preventSleepCharging

        updateAssertion(&idleSleepAssertion,
                        type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                        needed: protectingDischarge || protectingCharge)
        updateAssertion(&systemSleepAssertion,
                        type: kIOPMAssertionTypePreventSystemSleep as CFString,
                        needed: protectingDischarge)
    }

    private func updateAssertion(_ assertion: inout IOPMAssertionID, type: CFString, needed: Bool) {
        if needed, assertion == 0 {
            let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Vorssaint 主动放电睡眠保护" as CFString, &assertion)
            if result != kIOReturnSuccess {
                assertion = 0
                response.warning = "无法启用主动放电睡眠保护"
            }
        } else if !needed, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func releaseAssertion() {
        if idleSleepAssertion != 0 {
            IOPMAssertionRelease(idleSleepAssertion)
            idleSleepAssertion = 0
        }
        if systemSleepAssertion != 0 {
            IOPMAssertionRelease(systemSleepAssertion)
            systemSleepAssertion = 0
        }
    }

    private func power(_ type: UInt32, argument: UnsafeMutableRawPointer?) {
        diagnosticLog.notice("power notification type=\(type)")
        switch type {
        // IOMessage.h iokit_common_msg macros are unavailable to Swift.
        case 0xe0000270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case 0xe0000280: // kIOMessageSystemWillSleep
            sleeping = true
            releaseAssertion()
            if owner != nil { evaluate() }
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case 0xe0000300: // kIOMessageSystemHasPoweredOn
            sleeping = false
            // Let the authenticated app reconnect after wake; no battery drain during sleep.
            heartbeat = ProcessInfo.processInfo.systemUptime
            tick()
        default: break
        }
    }

    private func failure(_ message: String) -> Data {
        response.error = message
        return response.encoded
    }
}

private final class BatterySession: NSObject, BatteryControlXPCProtocol {
    let id = UUID()
    let controller: BatteryController
    init(_ controller: BatteryController) { self.controller = controller }
    func update(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async { reply(self.controller.update(data, session: self.id)) }
    }
    func command(_ name: String, withReply reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async { reply(self.controller.command(name, session: self.id)) }
    }
    func status(withReply reply: @escaping (Data) -> Void) {
        diagnosticLog.notice("status received session=\(self.id)")
        DispatchQueue.main.async { reply(self.controller.status()) }
    }
    func restore(withReply reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async { self.controller.reset(); reply(self.controller.status()) }
    }
    func prepareForRemoval(withReply reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async { self.controller.retire(); reply(self.controller.status()) }
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    let controller: BatteryController
    init(_ controller: BatteryController) { self.controller = controller }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        diagnosticLog.notice("XPC accepted peer pid=\(connection.processIdentifier)")
        let session = BatterySession(controller)
        connection.exportedInterface = NSXPCInterface(with: BatteryControlXPCProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { DispatchQueue.main.async { session.controller.disconnected(session.id) } }
        connection.activate()
        return true
    }
}

if CommandLine.arguments.contains("--selftest") {
    guard BatteryControlConfiguration().isValid else { exit(1) }
    print("battery-control-helper: policy and IPC loaded (no hardware writes)")
    exit(0)
}
if CommandLine.arguments.contains("--probe-system-limit") {
    // Standalone read-only capability query. Never creates BatteryController,
    // acquires ownership, restores a journal, registers a daemon or invokes setters.
    var result = BatteryControlResponse()
    result.interfaceDiagnostics = BatteryPowerUI.interfaceDiagnostics()
    do {
        let client = try BatteryPowerUI()
        result.systemChargeLimits = try client.availableLimits()
        result.systemLimitReadback = try client.read().limit
        result.systemPolicyLimit = BatteryPowerUI.policyLimit()
        result.systemChargeLimitBackend = true
        result.backendName = "PowerUI · 系统充电上限"
        result.supported = true
    } catch { result.error = error.localizedDescription }
    print(String(data: result.encoded, encoding: .utf8) ?? "{}")
    exit(result.error == nil ? 0 : 1)
}
if CommandLine.arguments.contains("--probe") {
    var result = BatteryControlResponse()
    let smc = SMCClient()
    result.interfaceDiagnostics = ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        + (smc?.batteryInterfaceDiagnostics() ?? "AppleSMC连接失败")
    do {
        let hardware = try BatteryControlHardware(validating: smc)
        result.supported = true
        result.backendName = hardware.backendName
        result.dischargeSupported = hardware.dischargeSupported
        result.ledSupported = hardware.ledSupported
        result.command = try hardware.state()
    } catch { result.error = error.localizedDescription }
    print(String(data: result.encoded, encoding: .utf8) ?? "{}")
    exit(result.supported && result.error == nil ? 0 : 1)
}
let maintenanceRequested = CommandLine.arguments.contains("--retire-for-registration-repair")
if CommandLine.arguments.contains("--verify-signing") || maintenanceRequested {
    // Read-only installation check: prove our pinned requirement accepts the
    // actual enclosing signed application, without registering or touching SMC.
    let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard let text = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.appID),
          SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
        print("battery-control-helper: enclosing app signing verification failed"); exit(1)
    }
    if !maintenanceRequested {
        print("battery-control-helper: pinned signing requirement accepts installed app")
        exit(0)
    }
}
if maintenanceRequested {
    func refuse(_ message: String) -> Never {
        diagnosticLog.error("维护停止：\(message, privacy: .public)")
        fputs("\(message)\n", stderr)
        exit(1)
    }
    guard geteuid() == 0 else { refuse("需要管理员授权；未修改后台。") }
    let ownership = BatteryOwnership()
    // Holding the same root-owned lock prevents BOTH installed variants from
    // taking control while launchd retires the old job. Never steal this lock.
    guard ownership.acquire() else { refuse("其他后台仍持有电池控制权。请先恢复自动充电；连接断开后可稍候再试。未停止任何后台。") }
    guard !BatterySystemLimitFileJournal().mayExist else {
        refuse("存在系统限充恢复记录；请先由原后台确认恢复，未停止后台或删除记录。")
    }
    var hardware: BatteryControlHardware?
    var interfaceUnavailable = false
    do {
        let detected = try BatteryControlHardware(validating: SMCClient())
        guard try detected.state() == .automatic else { refuse("充电或电源输入尚未恢复系统自动状态，未停止后台。") }
        hardware = detected
    } catch {
        if let failure = error as? BatteryControlHardware.ProbeFailure {
            switch failure {
            case .missing, .layout: interfaceUnavailable = true
            default: break
            }
        }
        guard interfaceUnavailable, ownership.recoveryRecordAbsent else {
            refuse("无法读取硬件状态且不满足无恢复记录迁移条件，未停止后台：\(error.localizedDescription)")
        }
        diagnosticLog.notice("接口未适配；已持独占锁且安全目录内无恢复记录，仅迁移注册，不宣称硬件恢复或限充生效")
    }
    let diagnosis = BatteryLaunchDiagnosis.inspect()
    guard diagnosis.readable || diagnosis.serviceMissing else { refuse(diagnosis.summary) }
    guard BatteryMaintenanceSafety.canStopService(lockHeld: ownership.held, command: try? hardware?.state(),
        jobReadable: diagnosis.readable || diagnosis.serviceMissing, interfaceUnavailable: interfaceUnavailable,
        recoveryRecordAbsent: ownership.recoveryRecordAbsent) else {
        refuse("停止服务前的安全复查未通过，未停止后台。")
    }
    let oldPID = diagnosis.processID
    guard oldPID != getpid() else { refuse("拒绝停止维护进程自身。") }
    diagnosticLog.notice("管理员维护：已取得控制权锁且安全迁移检查通过；停止服务 \(BatteryControlIdentifiers.helperID, privacy: .public)")
    // Stop the exact launchd job, not an arbitrary caller-supplied PID. Unlike
    // killing a process, bootout prevents KeepAlive from relaunching the old job.
    if !diagnosis.serviceMissing {
        let result = BoundedProcessRunner.run("/bin/launchctl", ["bootout", "system/" + BatteryControlIdentifiers.helperID],
                                          timeout: 65, maxOutputBytes: 8192)
        guard result.status == 0, !result.timedOut else {
            refuse("系统未确认旧服务退出，结果未知；保留恢复记录。\(String(decoding: result.output, as: UTF8.self))")
        }
    }
    if let oldPID {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var exited = false
        repeat {
            if kill(oldPID, 0) != 0 {
                exited = errno == ESRCH
                break
            }
            usleep(100_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard exited else { refuse("旧进程退出尚未确认，暂不注册新版。") }
    }
    guard BatteryMaintenanceSafety.canStopService(lockHeld: ownership.held, command: try? hardware?.state(),
        jobReadable: true, interfaceUnavailable: interfaceUnavailable,
        recoveryRecordAbsent: ownership.recoveryRecordAbsent) else {
        refuse("停止后安全复查未通过，保留恢复记录，请检查系统充电。")
    }
    ownership.release()
    print("BATTERY_MAINTENANCE_RETIRED=1")
    exit(0)
}
guard geteuid() == 0, let requirement = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.appID) else { exit(1) }
private let controller = BatteryController()
private let delegate = Listener(controller)
private let listener = NSXPCListener(machServiceName: BatteryControlIdentifiers.helperID)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.activate()
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
private let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { if controller.restore() { exit(0) } }
term.resume()
private let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { if controller.restore() { exit(0) } }
interrupt.resume()
RunLoop.main.run()
