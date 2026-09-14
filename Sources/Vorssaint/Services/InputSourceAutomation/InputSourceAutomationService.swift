// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class InputSourceAutomationService: ObservableObject {
    static let shared = InputSourceAutomationService()

    @Published private(set) var activeApplication: NSRunningApplication?
    @Published private(set) var activeDomain: String?
    @Published private(set) var isRunning = false

    private var workspaceObservers: [NSObjectProtocol] = []
    private var rulesObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var browserTimer: Timer?
    private var domainRequestInFlight = false
    private var domainGeneration = 0
    private var lastAppliedContext: String?
    private var programmaticChangeUntil = Date.distantPast
    private var manualOverrides: [String: (sourceID: String, expiresAt: Date)] = [:]
    private let manualOverrideDuration: TimeInterval = 15
    private let punctuation = EnglishPunctuationService()

    private init() {}

    func syncWithPreferences() {
        let enabled = AppFeature.inputSourceAutomation.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.inputSourceAutomationEnabled)
        if enabled { start() } else { stop() }
        punctuation.update(enabled: enabled,
                           bundleIDs: Set(InputSourceRuleStore.shared.appRules
                            .filter(\.forceEnglishPunctuation).map(\.bundleID)))
    }

    func refreshMenuContext() {
        guard let app = Self.externalFrontmostApplication() else { return }
        if activeApplication?.processIdentifier != app.processIdentifier {
            activeApplication = app
            activeDomain = nil
        }
        // Domain discovery is still available when creating the first rule.
        if Self.browserBundleIDs.contains(app.bundleIdentifier ?? "") {
            requestDomain(for: app)
        }
    }

    private func start() {
        guard !isRunning else {
            refreshActiveApplication()
            return
        }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshActiveApplication() }
            })
        }
        rulesObserver = NotificationCenter.default.addObserver(
            forName: .inputSourceAutomationRulesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.punctuation.update(enabled: true,
                    bundleIDs: Set(InputSourceRuleStore.shared.appRules
                        .filter(\.forceEnglishPunctuation).map(\.bundleID)))
                if let context = self.currentContextKey { self.manualOverrides.removeValue(forKey: context) }
                self.applyCurrentContext(force: true)
                if let app = self.activeApplication { self.configureBrowserPolling(for: app) }
            }
        }
        let inputSourceChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: inputSourceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.inputSourceDidChange() }
        }
        refreshActiveApplication()
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        domainGeneration &+= 1
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        if let rulesObserver { NotificationCenter.default.removeObserver(rulesObserver) }
        rulesObserver = nil
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        }
        inputSourceObserver = nil
        browserTimer?.invalidate()
        browserTimer = nil
        activeDomain = nil
        lastAppliedContext = nil
        manualOverrides.removeAll()
        punctuation.update(enabled: false, bundleIDs: [])
    }

    private func refreshActiveApplication() {
        // Normal activation must include Vorssaint itself. The Settings window can
        // have its own app rule; filtering our PID here left the previous external
        // app cached, so a rule for the Developer build never took effect. Only
        // refreshMenuContext() deliberately skips our process, because opening the
        // menu bar panel should continue to describe the app behind the panel.
        guard isRunning, let app = NSWorkspace.shared.frontmostApplication else { return }
        activeApplication = app
        activeDomain = nil
        punctuation.setActiveBundleID(app.bundleIdentifier)
        applyCurrentContext(force: true)
        configureBrowserPolling(for: app)
    }

    private func configureBrowserPolling(for app: NSRunningApplication) {
        browserTimer?.invalidate()
        browserTimer = nil
        guard isRunning, !InputSourceRuleStore.shared.domainRules.isEmpty,
              Self.browserBundleIDs.contains(app.bundleIdentifier ?? "") else { return }
        requestDomain(for: app)
        browserTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self, weak app] _ in
            Task { @MainActor [weak self, weak app] in
                guard let self, let app else { return }
                self.requestDomain(for: app)
            }
        }
    }

    private func requestDomain(for app: NSRunningApplication) {
        guard !domainRequestInFlight, app.processIdentifier == activeApplication?.processIdentifier else { return }
        domainRequestInFlight = true
        let pid = app.processIdentifier
        let generation = domainGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let domain = BrowserDomainResolver.domain(processIdentifier: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.domainRequestInFlight = false
                guard self.domainGeneration == generation,
                      self.activeApplication?.processIdentifier == pid else { return }
                if self.activeDomain != domain {
                    self.activeDomain = domain
                    self.applyCurrentContext(force: true)
                }
            }
        }
    }

    private func applyCurrentContext(force: Bool) {
        guard isRunning, let bundleID = activeApplication?.bundleIdentifier else { return }
        let store = InputSourceRuleStore.shared
        let domainRule = activeDomain.flatMap {
            InputSourceRuleSupport.matchingRule(for: $0, rules: store.domainRules)
        }
        let configuredSourceID = domainRule?.sourceID
            ?? store.appRules.first(where: { $0.bundleID == bundleID })?.sourceID
        guard let configuredSourceID, !configuredSourceID.isEmpty,
              let contextKey = currentContextKey else { return }
        let context = "\(contextKey)|\(configuredSourceID)"
        guard force || context != lastAppliedContext else { return }
        lastAppliedContext = context

        let now = Date()
        manualOverrides = manualOverrides.filter { $0.value.expiresAt > now }
        let sourceID: String
        if let override = manualOverrides[contextKey], override.expiresAt > now {
            sourceID = override.sourceID
        } else if InputSourceRuleSupport.isFollowLastUsed(configuredSourceID) {
            guard let remembered = store.rememberedSource(for: contextKey) else {
                if let current = ManagedInputSource.current?.id {
                    store.rememberSource(current, for: contextKey)
                }
                return
            }
            sourceID = remembered
        } else {
            sourceID = configuredSourceID
        }
        if ManagedInputSource.current?.id != sourceID {
            programmaticChangeUntil = Date().addingTimeInterval(1)
            _ = ManagedInputSource.select(persistentID: sourceID)
        }
    }

    private var currentContextKey: String? {
        guard let bundleID = activeApplication?.bundleIdentifier else { return nil }
        if let domain = activeDomain,
           InputSourceRuleSupport.matchingRule(for: domain,
                                                rules: InputSourceRuleStore.shared.domainRules) != nil {
            return "website|\(domain)"
        }
        return "app|\(bundleID)"
    }

    private func inputSourceDidChange() {
        guard isRunning, Date() >= programmaticChangeUntil,
              let context = currentContextKey,
              let sourceID = ManagedInputSource.current?.id else { return }
        InputSourceRuleStore.shared.rememberSource(sourceID, for: context)
        manualOverrides[context] = (sourceID, Date().addingTimeInterval(manualOverrideDuration))
    }

    private static func externalFrontmostApplication() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ownPID { return front }
        return NSWorkspace.shared.runningApplications.first {
            $0.isActive && $0.processIdentifier != ownPID
        }
    }

    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "app.zen-browser.zen", "company.thebrowser.dia"
    ]
}

private enum BrowserDomainResolver {
    private static let urlAttribute = "AXURL" as CFString

    static func domain(processIdentifier pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &windowValue) == .success,
              let windowValue else { return nil }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        var queue = [window]
        var offset = 0
        while offset < queue.count, offset < 700 {
            let element = queue[offset]
            offset += 1
            if let rawURL = stringValue(element, attribute: urlAttribute),
               let domain = InputSourceRuleSupport.normalizedDomain(rawURL) { return domain }
            if looksLikeAddressField(element),
               let value = stringValue(element, attribute: kAXValueAttribute as CFString),
               let domain = InputSourceRuleSupport.normalizedDomain(value) { return domain }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                             &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(120))
            }
        }
        return nil
    }

    private static func looksLikeAddressField(_ element: AXUIElement) -> Bool {
        let role = stringValue(element, attribute: kAXRoleAttribute as CFString) ?? ""
        guard role == kAXTextFieldRole as String || role == kAXComboBoxRole as String else { return false }
        let hints = [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute]
            .compactMap { stringValue(element, attribute: $0 as CFString)?.lowercased() }
            .joined(separator: " ")
        return hints.contains("address") || hints.contains("url") || hints.contains("location")
            || hints.contains("omnibox") || hints.contains("search") || hints.contains("网址")
            || hints.contains("地址")
    }

    private static func stringValue(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }
}

private final class EnglishPunctuationService {
    private let lock = NSLock()
    private var enabledBundleIDs = Set<String>()
    private var activeBundleID: String?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func update(enabled: Bool, bundleIDs: Set<String>) {
        lock.lock(); enabledBundleIDs = bundleIDs; lock.unlock()
        if enabled && !bundleIDs.isEmpty { start() } else { stop() }
    }

    func setActiveBundleID(_ bundleID: String?) {
        lock.lock(); activeBundleID = bundleID; lock.unlock()
    }

    private func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<EnglishPunctuationService>.fromOpaque(userInfo).takeUnretainedValue()
            return service.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        lock.lock()
        let shouldReplace = activeBundleID.map(enabledBundleIDs.contains) ?? false
        lock.unlock()
        guard shouldReplace else { return Unmanaged.passUnretained(event) }
        let blocked: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        guard event.flags.intersection(blocked).isEmpty else { return Unmanaged.passUnretained(event) }
        let shifted = event.flags.contains(.maskShift)
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let pair = Self.characters[key], let replacement = shifted ? pair.1 : pair.0 else {
            return Unmanaged.passUnretained(event)
        }
        guard let replacementEvent = event.copy() else { return Unmanaged.passUnretained(event) }
        let utf16 = Array(replacement.utf16)
        replacementEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        replacementEvent.flags = []
        return Unmanaged.passRetained(replacementEvent)
    }

    private static let characters: [UInt16: (String?, String?)] = [
        UInt16(kVK_ANSI_Grave): ("`", "~"), UInt16(kVK_ANSI_4): (nil, "$"),
        UInt16(kVK_ANSI_6): (nil, "^"), UInt16(kVK_ANSI_Minus): ("-", "_"),
        UInt16(kVK_ANSI_Comma): (",", "<"), UInt16(kVK_ANSI_Period): (".", ">"),
        UInt16(kVK_ANSI_Semicolon): (";", ":"), UInt16(kVK_ANSI_Quote): ("'", "\""),
        UInt16(kVK_ANSI_Backslash): ("\\", "|"), UInt16(kVK_ANSI_LeftBracket): ("[", "{"),
        UInt16(kVK_ANSI_RightBracket): ("]", "}")
    ]
}
