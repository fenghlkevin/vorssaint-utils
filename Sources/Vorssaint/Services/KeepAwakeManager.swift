// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt

/// Core of the energy feature: manages "keep awake" sessions through IOKit power
/// assertions, the closed-lid mode (pmset disablesleep, administrator password)
/// and the battery protection watchdog.
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager()

    enum EndReason { case manual, timer, battery, quit }
    enum SessionTrigger { case manual, automation }

    @Published private(set) var isActive = false
    @Published private(set) var endDate: Date? // nil = indefinite
    @Published private(set) var sessionTrigger: SessionTrigger?
    @Published private(set) var activeAutomationConditions = Set<KeepAwakeAutomationCondition>()
    @Published private(set) var clamshellActive = false
    @Published private(set) var passwordlessClamshell = false
    @Published private(set) var clamshellSetupInProgress = false
    @Published private(set) var clamshellSetupFailed = false
    @Published private(set) var effectiveMode: PowerIdleMode = .system
    @Published private(set) var onBattery = true
    @Published private(set) var externalConnected = false
    @Published private(set) var temporaryMode: PowerIdleMode?
    @Published private(set) var actionError: String?
    @Published private(set) var sleepInProgress = false
    private var sessionLocked = false
    private var policySuspended = false
    private var manualPause = false
    private var sleepRequestID = UUID()
    private var sleepObserved = false
    private var batteryProtectionPausedForLock = false
    private var displayObserver: AnyCancellable?
    private var wantsClosedLid = false
    private var clamshellWriteInFlight = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var automaticDisplayIDs = Set<CGDirectDisplayID>()
    private var previousDisplayContext: String?


    var onSessionEnded: ((EndReason) -> Void)?

    private var systemAssertion = IOPMAssertionID(0)
    private var displayAssertion = IOPMAssertionID(0)
    private var hasSystemAssertion = false
    private var hasDisplayAssertion = false
    private var endTimer: Timer?
    private var batteryTimer: Timer?
    private var mouseJiggleTimer: Timer?
    private var pendingMouseReturn: DispatchWorkItem?
    private var defaultsObserver: AnyCancellable?
    private var screenParametersObserver: NSObjectProtocol?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var automationEvaluationWorkItem: DispatchWorkItem?
    private var lastExternalDisplayConnected: Bool?
    private var automationSuppressedUntilConditionsClear = false
    private var recoveryCompleted = false
    /// Guards the closed-lid setup against an infinite retry loop: if `pmset
    /// disablesleep` keeps failing while the sudoers rule still checks out as
    /// installed, re-preparing would bounce here forever (and flicker the
    /// caption). One automatic re-acquire per user attempt, then we give up.
    private var clamshellSetupRetried = false
    /// A reply to a settings change already waiting for the next run loop turn.
    private var preferenceSyncScheduled = false

    private init() {
        for battery in [true, false] {
            PowerDisplayProfile.read(onBattery: battery).save(onBattery: battery)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        sessionLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        lifecycleObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.policySuspended = false
            self.sleepInProgress = false
            self.sleepRequestID = UUID()
            self.batteryProtectionPausedForLock = false
            BatteryManagementService.shared.resumeSleepProtection()
            self.scheduleAutomationEvaluation(after: 1)
        })
        lifecycleObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleepObserved = true
        })
        displayObserver = BrightnessService.shared.$displays
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluateAutomation() }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.sessionLocked = locked
                self?.evaluateAutomation()
            })
        }
        refreshPasswordlessStatus()
        // Every settings write announces itself, including the ones made from
        // inside this class, so a burst folds into a single reply on the next
        // turn of the run loop rather than one full pass per write.
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self, !self.preferenceSyncScheduled else { return }
                self.preferenceSyncScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.preferenceSyncScheduled = false
                    self.syncWithPreferences()
                }
            }
    }

    /// Refreshes (in the background) whether the closed-lid sudoers rule is installed.
    func refreshPasswordlessStatus() {
        DispatchQueue.global(qos: .utility).async {
            let configured = Sudoers.isConfigured()
            DispatchQueue.main.async {
                self.passwordlessClamshell = configured
            }
        }
    }

    // MARK: - Session

    func toggle() {
        if isActive {
            selectMode(.system, minutes: 0)
            manualPause = true
            evaluateAutomation()
        }
        else { selectMode(.bright, minutes: UserDefaults.standard.integer(forKey: DefaultsKey.defaultDuration)) }
    }


    /// Keep Awake leaving the hub ends any running session; everything else
    /// (saved duration, tint, shortcut setting) stays for its return.
    func syncWithFeatures() {
        guard AppFeature.keepAwake.isAvailable else {
            wantsClosedLid = false
            temporaryMode = nil
            if batteryProtectionPausedForLock {
                batteryProtectionPausedForLock = false
                BatteryManagementService.shared.resumeSleepProtection()
            }
            var restoreProfile = currentProfile
            restoreProfile.hideInternal = false
            previousDisplayContext = nil
            syncInternalDisplay(profile: restoreProfile)
            stopAutomationMonitoring()
            if isActive { deactivate(reason: .manual) }
            return
        }
        syncWithPreferences()
    }

    func syncWithPreferences() {
        syncAutomationMonitoring()
    }

    /// Called by automation controls so a deliberate preference change can
    /// resume evaluation after a manually stopped automatic session.
    func automationPreferencesDidChange() {
        automationSuppressedUntilConditionsClear = false
        syncWithPreferences()
    }

    /// `minutes <= 0` activates indefinitely.
    func activate(minutes: Int) {
        selectMode(UserDefaults.standard.bool(forKey: DefaultsKey.keepAwakeAllowDisplaySleep) ? .awake : .bright,
                   minutes: minutes)
    }

    private func activate(minutes: Int, trigger: SessionTrigger) {
        guard AppFeature.keepAwake.isAvailable else { return }
        let minutes = Defaults.sanitizedDefaultDuration(minutes)
        endTimer?.invalidate()
        endTimer = nil
        applyAssertions()
        sessionTrigger = trigger
        if trigger == .manual {
            activeAutomationConditions.removeAll()
        }
        isActive = true
        if minutes > 0 {
            let end = Date().addingTimeInterval(TimeInterval(minutes) * 60)
            endDate = end
            scheduleEnd(at: end)
        } else {
            endDate = nil
        }
        startBatteryWatch()
        syncMouseJiggleTimer()
        if wantsClosedLid {
            applyClamshellPreference()
        }
    }

    func activateOnLaunchIfNeeded() {
        guard AppFeature.keepAwake.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.keepAwakeAutoStart),
              !isActive else { return }
        activate(minutes: Defaults.sanitizedDefaultDuration(
            UserDefaults.standard.integer(forKey: DefaultsKey.defaultDuration)))
    }

    func extend(minutes: Int) {
        guard isActive, let current = endDate else { return }
        let newEnd = max(current, Date()).addingTimeInterval(TimeInterval(minutes) * 60)
        endDate = newEnd
        scheduleEnd(at: newEnd)
    }

    func deactivate(reason: EndReason) {
        let hadSession = isActive
        if reason == .quit {
            policySuspended = true
            wantsClosedLid = false
            stopAutomationMonitoring()
        }
        if !(reason == .manual && sessionLocked && temporaryMode != nil && !policySuspended) {
            endTimer?.invalidate()
            endTimer = nil
            endDate = nil
        }
        releaseAssertions()
        if clamshellActive || (reason == .quit && clamshellWriteInFlight) {
            disableClamshell(synchronous: reason == .quit)
        }
        sessionTrigger = nil
        activeAutomationConditions.removeAll()
        isActive = false
        stopBatteryWatch()
        stopMouseJiggleTimer()
        if hadSession, reason != .quit, reason != .manual {
            onSessionEnded?(reason)
        }
    }

    // MARK: - Power and display policy

    var currentProfile: PowerDisplayProfile { PowerDisplayProfile.read(onBattery: onBattery) }

    func updateProfile(_ profile: PowerDisplayProfile, onBattery: Bool) {
        objectWillChange.send()
        manualPause = false
        profile.save(onBattery: onBattery)
        previousDisplayContext = nil
        evaluateAutomation()
    }

    func authorizeClosedLid() {
        actionError = nil
        prepareClamshellPreference()
    }

    func selectMode(_ mode: PowerIdleMode, minutes: Int) {
        guard !sleepInProgress else { return }
        temporaryMode = mode
        manualPause = false
        actionError = nil
        endTimer?.invalidate()
        endTimer = nil
        endDate = nil
        evaluateAutomation()
        let duration = Defaults.sanitizedDefaultDuration(minutes)
        if mode != .system, duration > 0 {
            let date = Date().addingTimeInterval(Double(duration * 60))
            endDate = date
            scheduleEnd(at: date)
        }
    }

    func resumeDefaultPolicy() {
        manualPause = false
        temporaryMode = nil
        endTimer?.invalidate()
        endTimer = nil
        endDate = nil
        evaluateAutomation()
    }

    private func evaluatePowerDisplayPolicy() {
        let battery = SystemInfo.batterySnapshot()
        let batterySource = battery?.isOnBattery ?? PowerSampler.hasInternalBattery
        if onBattery != batterySource { onBattery = batterySource }
        // Active, physical external displays only: a virtual or disabled screen
        // must never keep a closed laptop running after its cable is removed.
        let external = Self.hasExternalDisplay() ?? false
        if externalConnected != external { externalConnected = external }
        let profile = currentProfile
        if !policySuspended {
            let pauseBattery = sessionLocked && profile.locked == .system && AppFeature.keepAwake.isAvailable
            if pauseBattery != batteryProtectionPausedForLock {
                batteryProtectionPausedForLock = pauseBattery
                if pauseBattery {
                    BatteryManagementService.shared.prepareForSystemSleep { [weak self] ok in
                        if !ok { self?.actionError = "电池后台未确认暂停防休眠；锁屏后可能仍保持运行。" }
                    }
                } else { BatteryManagementService.shared.resumeSleepProtection() }
            }
        }
        let limit = Defaults.sanitizedBatteryLimit(UserDefaults.standard.integer(forKey: DefaultsKey.batteryLimit))
        let low = onBattery && limit > 0 && (battery?.percent ?? 0) <= limit
        let decision = PowerDisplayDecision.resolve(profile: profile, external: external,
            locked: sessionLocked, temporary: temporaryMode, lowBattery: low,
            suspended: policySuspended || manualPause || !AppFeature.keepAwake.isAvailable)
        wantsClosedLid = decision.closedLid
        if effectiveMode != decision.mode { effectiveMode = decision.mode }
        let needed = decision.mode != .system || (decision.closedLid && passwordlessClamshell)
        if needed, !isActive {
            let expiry = endDate
            activate(minutes: 0, trigger: temporaryMode == nil ? .automation : .manual)
            if let expiry, expiry > Date() { endDate = expiry; scheduleEnd(at: expiry) }
        } else if !needed, isActive {
            deactivate(reason: .manual)
        }
        if needed { applyAssertions() }
        if needed { sessionTrigger = temporaryMode == nil ? .automation : .manual }
        if !wantsClosedLid, clamshellActive { disableClamshell(synchronous: false) }
        if wantsClosedLid, passwordlessClamshell { enableClamshell() }
        syncMouseJiggleTimer()
        if !policySuspended, !sessionLocked, AppFeature.keepAwake.isAvailable {
            syncInternalDisplay(profile: profile)
        }
    }

    private func syncInternalDisplay(profile: PowerDisplayProfile) {
        guard AppFeature.brightness.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.brightnessControlEnabled) else { return }
        let service = BrightnessService.shared
        let context = "\(onBattery)-\(externalConnected)-\(profile.hideInternal)"
        guard previousDisplayContext != context, !service.displays.isEmpty else { return }
        let candidates = service.displays.filter { $0.isBuiltIn }
        guard !candidates.isEmpty else { return }
        for display in candidates {
            let hide = profile.hideInternal && externalConnected
            if hide, display.isActive {
                guard service.canToggleDisplay(display), !service.isDisplayPending(display.id) else { return }
                automaticDisplayIDs.insert(display.id)
                service.toggleDisplay(display)
            } else if !hide, !display.isActive, automaticDisplayIDs.contains(display.id) {
                guard service.canToggleDisplay(display), !service.isDisplayPending(display.id) else { return }
                service.toggleDisplay(display)
                automaticDisplayIDs.remove(display.id)
            }
        }
        previousDisplayContext = context
    }

    func lockScreen() {
        if !QuickTogglesService.shared.lockForPowerManagement() {
            actionError = "系统锁屏接口不可用，请使用 Control–Command–Q 锁屏。"
        }
    }

    func sleepNow() {
        guard !sleepInProgress else { return }
        actionError = nil
        sleepInProgress = true
        sleepRequestID = UUID()
        sleepObserved = false
        policySuspended = true
        temporaryMode = nil
        manualPause = false
        wantsClosedLid = false
        deactivate(reason: .manual)
        prepareSystemSleep(attempt: 0)
    }

    private func prepareSystemSleep(attempt: Int) {
        let request = sleepRequestID
        guard attempt < 40 else { failSleep("恢复合盖睡眠超时，请重新授权后重试。"); return }
        if clamshellWriteInFlight {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard self.sleepRequestID == request, self.sleepInProgress else { return }
                self.prepareSystemSleep(attempt: attempt + 1)
            }
            return
        }
        if clamshellActive || UserDefaults.standard.bool(forKey: DefaultsKey.sleepDisabledFlag) {
            failSleep("合盖防休眠尚未解除，请重新授权后重试。")
            return
        }
        BatteryManagementService.shared.prepareForSystemSleep { [weak self] ok in
            guard let self, self.sleepRequestID == request, self.sleepInProgress else { return }
            guard ok else { self.failSleep("电池后台尚未确认解除防休眠，请等待后台连接正常后重试。"); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let state = Shell.run("/usr/bin/pmset", ["-g"])
                guard state.status == 0, !SudoersSupport.sleepDisabled(inPmsetOutput: state.output) else {
                    DispatchQueue.main.async {
                        guard self.sleepRequestID == request else { return }
                        self.failSleep("系统仍禁用了睡眠，或无法读取电源状态；请重新授权后重试。")
                    }
                    return
                }
                let result = Shell.run("/usr/bin/pmset", ["sleepnow"])
                DispatchQueue.main.async {
                    guard self.sleepRequestID == request else { return }
                    if result.status != 0 { self.failSleep("系统未接受休眠请求：\(result.output)") }
                }
            }
            // If another application refuses sleep, do not leave this UI busy forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.sleepInProgress, self.sleepRequestID == request, !self.sleepObserved else { return }
                self.failSleep("系统尚未进入休眠；已恢复默认策略，请检查其他应用的防休眠设置。")
            }
        }
    }

    private func failSleep(_ message: String) {
        actionError = message
        sleepInProgress = false
        sleepRequestID = UUID()
        policySuspended = false
        batteryProtectionPausedForLock = false
        BatteryManagementService.shared.resumeSleepProtection()
        evaluateAutomation()
    }

    // MARK: - Automatic sessions

    private func syncAutomationMonitoring() {
        let available = AppFeature.keepAwake.isAvailable
        let observeScreens = available
        let observePower = available

        setScreenMonitoringEnabled(observeScreens)
        setPowerMonitoringEnabled(observePower)
        evaluateAutomation()
    }

    private func setScreenMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            guard screenParametersObserver == nil else { return }
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleAutomationEvaluation(after: 0.35)
            }
        } else if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
            lastExternalDisplayConnected = nil
        }
    }

    private func setPowerMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            guard powerSourceRunLoopSource == nil else { return }
            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            powerSourceRunLoopSource = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let manager = Unmanaged<KeepAwakeManager>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.scheduleAutomationEvaluation(after: 0.1)
                }
            }, context)?.takeRetainedValue()
            if let powerSourceRunLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            }
        } else if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            self.powerSourceRunLoopSource = nil
        }
    }

    private func scheduleAutomationEvaluation(after delay: TimeInterval) {
        automationEvaluationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.automationEvaluationWorkItem = nil
            self?.evaluateAutomation()
        }
        automationEvaluationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopAutomationMonitoring() {
        automationEvaluationWorkItem?.cancel()
        automationEvaluationWorkItem = nil
        setScreenMonitoringEnabled(false)
        setPowerMonitoringEnabled(false)
        activeAutomationConditions.removeAll()
    }

    private func evaluateAutomation() {
        guard recoveryCompleted else { return }
        evaluatePowerDisplayPolicy()
    }


    private static func hasExternalDisplay() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).contains {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0
                && !BrightnessService.isVirtualDisplay($0)
        }
    }


    private func scheduleEnd(at date: Date) {
        endTimer?.invalidate()
        let t = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.temporaryMode = nil
            self.deactivate(reason: .timer)
            self.evaluateAutomation()
        }
        RunLoop.main.add(t, forMode: .common)
        endTimer = t
    }

    // MARK: - IOKit assertions

    private func applyAssertions() {
        if effectiveMode == .system {
            releaseAssertions()
            return
        }
        if !hasSystemAssertion {
            var id = IOPMAssertionID(0)
            let ok = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Vorssaint: keep the Mac awake" as CFString,
                                                 &id)
            if ok == kIOReturnSuccess {
                systemAssertion = id
                hasSystemAssertion = true
            } else {
                actionError = "系统未接受保持运行请求（\(ok)），请重试。"
            }
        }
        let allowDisplaySleep = effectiveMode != .bright
        if allowDisplaySleep, hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertion)
            hasDisplayAssertion = false
        } else if !allowDisplaySleep, !hasDisplayAssertion {
            var id = IOPMAssertionID(0)
            let ok = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Vorssaint: keep the display on" as CFString,
                                                 &id)
            if ok == kIOReturnSuccess {
                displayAssertion = id
                hasDisplayAssertion = true
            } else {
                actionError = "系统未接受屏幕常亮请求（\(ok)），请重试。"
            }
        }
    }

    private func releaseAssertions() {
        if hasSystemAssertion {
            IOPMAssertionRelease(systemAssertion)
            hasSystemAssertion = false
        }
        if hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertion)
            hasDisplayAssertion = false
        }
    }

    // MARK: - Closed lid (pmset disablesleep)

    private func applyClamshellPreference() {
        // A fresh user-driven attempt (toggle on, or a new session) gets one
        // automatic setup retry again.
        clamshellSetupRetried = false
        if passwordlessClamshell {
            if wantsClosedLid {
                enableClamshell()
            }
        }
    }

    private func prepareClamshellPreference() {
        guard !clamshellSetupInProgress else { return }
        clamshellSetupInProgress = true
        clamshellSetupFailed = false

        DispatchQueue.global(qos: .userInitiated).async {
            if Sudoers.isConfigured() {
                DispatchQueue.main.async {
                    self.finishClamshellSetup(ok: true)
                }
                return
            }

            Sudoers.install { ok in
                DispatchQueue.main.async {
                    self.finishClamshellSetup(ok: ok)
                }
            }
        }
    }

    private func finishClamshellSetup(ok: Bool) {
        clamshellSetupInProgress = false
        passwordlessClamshell = ok

        guard ok else {
            markClamshellSetupFailed()
            return
        }

        evaluateAutomation()
    }

    /// Authorization failures are visible without discarding the chosen profile.
    private func markClamshellSetupFailed() {
        clamshellSetupInProgress = false
        clamshellSetupFailed = true
        actionError = "合盖运行尚未授权，可点击授权按钮重试。"
    }

    private func enableClamshell() {
        guard wantsClosedLid, !clamshellActive, !clamshellWriteInFlight else { return }
        clamshellWriteInFlight = true
        // Persist before dispatch so a crash during the privileged write is recoverable.
        UserDefaults.standard.set(true, forKey: DefaultsKey.sleepDisabledFlag)
        Sudoers.pmsetDisableSleep(true) { ok in
            DispatchQueue.main.async {
                self.clamshellWriteInFlight = false
                guard ok else {
                    // The rule was reported as working but the real call failed.
                    // Never fall back to a password prompt here: prompting per
                    // toggle is exactly the grind of issue #269. Repair the rule
                    // once through the regular setup; if that does not restore
                    // the passwordless path, stop and report the failure.
                    self.passwordlessClamshell = false
                    self.clamshellSetupFailed = true
                    self.actionError = "合盖授权失效，请重新授权后重试。"
                    return
                }
                self.passwordlessClamshell = true
                UserDefaults.standard.set(true, forKey: DefaultsKey.sleepDisabledFlag)
                if self.wantsClosedLid, !self.policySuspended {
                    self.clamshellActive = true
                } else {
                    // The session ended (or the preference flipped) while the
                    // setup was still running — restore normal sleep.
                    self.disableClamshell(synchronous: false)
                }
            }
        }
    }

    private func disableClamshell(synchronous: Bool) {
        if synchronous {
            // The serialized Sudoers queue drains any outstanding enable first.
            if Sudoers.pmsetDisableSleep(false) {
                clamshellActive = false
                UserDefaults.standard.set(false, forKey: DefaultsKey.sleepDisabledFlag)
            }
            clamshellWriteInFlight = false
            return
        }
        guard !clamshellWriteInFlight else { return }
        clamshellWriteInFlight = true
        let finish: (Bool) -> Void = { [synchronous] usedPasswordless in
            // Quitting is the one moment where asking for a password is not
            // an option: the dialog would hold the app open until somebody
            // answers it, and nobody is watching an app that is closing. The
            // next start repairs a revert that was missed.
            let ok = usedPasswordless
                || (!synchronous
                    && AdminShell.runSync("pmset disablesleep 0",
                                          prompt: L10n.shared.s.adminPromptClamshellOff))
            DispatchQueue.main.async {
                self.clamshellWriteInFlight = false
                if ok {
                    self.clamshellActive = false
                    if !usedPasswordless {
                        self.passwordlessClamshell = false
                    }
                    UserDefaults.standard.set(false, forKey: DefaultsKey.sleepDisabledFlag)
                    if !self.policySuspended { self.evaluateAutomation() }
                } else {
                    self.actionError = "无法恢复系统睡眠，请重试或重新授权。"
                }
            }
        }
        if synchronous {
            finish(Sudoers.pmsetDisableSleep(false))
        } else {
            Sudoers.pmsetDisableSleep(false, completion: finish)
        }
    }

    /// If the app died unexpectedly while sleep was disabled, restores normal
    /// behavior on the next launch.
    func recoverIfNeeded(completion: (() -> Void)? = nil) {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.sleepDisabledFlag) else {
            finishRecovery(completion)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let out = Shell.run("/usr/bin/pmset", ["-g"]).output
            let stillDisabled = SudoersSupport.sleepDisabled(inPmsetOutput: out)
            if stillDisabled, Sudoers.pmsetDisableSleep(false) {
                // Silent recovery through the password-free path.
                DispatchQueue.main.async {
                    UserDefaults.standard.set(false, forKey: DefaultsKey.sleepDisabledFlag)
                    self.finishRecovery(completion)
                }
                return
            }
            DispatchQueue.main.async {
                if stillDisabled {
                    AdminShell.run("pmset disablesleep 0", prompt: L10n.shared.s.adminPromptRecover) { ok in
                        DispatchQueue.main.async {
                            if ok {
                                UserDefaults.standard.set(false, forKey: DefaultsKey.sleepDisabledFlag)
                            }
                            self.finishRecovery(completion)
                        }
                    }
                } else {
                    UserDefaults.standard.set(false, forKey: DefaultsKey.sleepDisabledFlag)
                    self.finishRecovery(completion)
                }
            }
        }
    }

    private func finishRecovery(_ completion: (() -> Void)?) {
        recoveryCompleted = true
        completion?()
        syncWithPreferences()
    }

    // MARK: - Battery protection

    private func startBatteryWatch() {
        stopBatteryWatch()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkBattery()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        batteryTimer = t
        checkBattery()
    }

    private func stopBatteryWatch() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    private func checkBattery() {
        evaluateAutomation()
        let limit = Defaults.sanitizedBatteryLimit(UserDefaults.standard.integer(forKey: DefaultsKey.batteryLimit))
        guard limit > 0, isActive else { return }
        guard let battery = SystemInfo.batterySnapshot(),
              battery.isOnBattery,
              battery.percent <= limit else { return }
        deactivate(reason: .battery)
    }

    // MARK: - Optional pointer activity

    private func syncMouseJiggleTimer() {
        guard isActive,
              effectiveMode != .system,
              !sessionLocked,
              UserDefaults.standard.bool(forKey: DefaultsKey.keepAwakeMouseJiggleEnabled)
        else {
            stopMouseJiggleTimer()
            return
        }

        let minutes = Defaults.sanitizedKeepAwakeMouseJiggleInterval(
            UserDefaults.standard.integer(forKey: DefaultsKey.keepAwakeMouseJiggleInterval)
        )
        let interval = TimeInterval(minutes * 60)
        if mouseJiggleTimer?.timeInterval == interval { return }

        stopMouseJiggleTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.jiggleMousePointer()
        }
        timer.tolerance = min(10, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        mouseJiggleTimer = timer
    }

    private func stopMouseJiggleTimer() {
        mouseJiggleTimer?.invalidate()
        mouseJiggleTimer = nil
        pendingMouseReturn?.cancel()
        pendingMouseReturn = nil
    }

    private func jiggleMousePointer() {
        guard isActive,
              UserDefaults.standard.bool(forKey: DefaultsKey.keepAwakeMouseJiggleEnabled),
              let original = Self.currentMouseLocation(),
              let target = Self.mouseJiggleTarget(from: original)
        else {
            syncMouseJiggleTimer()
            return
        }

        guard Self.postMouseMove(to: target) else { return }

        pendingMouseReturn?.cancel()
        let returnMove = DispatchWorkItem { [weak self] in
            self?.pendingMouseReturn = nil
            guard let current = Self.currentMouseLocation() else { return }
            guard abs(current.x - target.x) <= 2,
                  abs(current.y - target.y) <= 2 else { return }
            _ = Self.postMouseMove(to: original)
        }
        pendingMouseReturn = returnMove
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: returnMove)
    }

    private static func currentMouseLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    private static func mouseJiggleTarget(from original: CGPoint) -> CGPoint? {
        guard let bounds = displayBounds(containing: original) else { return nil }
        let safeFrame = bounds.insetBy(dx: 2, dy: 2)
        let x = min(max(original.x, safeFrame.minX), safeFrame.maxX)
        let y = min(max(original.y, safeFrame.minY), safeFrame.maxY)

        if x + 1 <= safeFrame.maxX {
            return CGPoint(x: x + 1, y: y)
        }
        if x - 1 >= safeFrame.minX {
            return CGPoint(x: x - 1, y: y)
        }
        if y + 1 <= safeFrame.maxY {
            return CGPoint(x: x, y: y + 1)
        }
        if y - 1 >= safeFrame.minY {
            return CGPoint(x: x, y: y - 1)
        }
        return nil
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return nil
        }

        for display in displays.prefix(Int(count)) {
            let bounds = CGDisplayBounds(display)
            if point.x >= bounds.minX, point.x <= bounds.maxX,
               point.y >= bounds.minY, point.y <= bounds.maxY {
                return bounds
            }
        }
        return nil
    }

    private static func postMouseMove(to point: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: point,
                                  mouseButton: .left) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }
}
