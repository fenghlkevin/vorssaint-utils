// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// Preserve the divider interaction, but use native visibility on macOS 27.
/// Earlier systems continue using the public status-item spacer mechanism.
final class MenuBarIconCollapser: NSObject, ObservableObject {
    static let shared = MenuBarIconCollapser()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isCollapsed: Bool
    @Published private(set) var placementIsSafe = false
    @Published private(set) var placementError = false
    @Published private(set) var autoCollapseDelay: Int
    @Published private(set) var operationError: String?
    @Published private(set) var isTransitioning = false
    @Published private(set) var revealMode = MenuBarRevealMode.menuBar
    @Published private(set) var expandOnHover = false
    @Published private(set) var showShelfNames = true
    @Published private(set) var isShelfShown = false

    private weak var mainStatusItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var dividerConstraint: NSLayoutConstraint?
    private let defaults = UserDefaults.standard
    private var autoCollapseTimer: Timer?
    private var startupCollapseWork: DispatchWorkItem?
    private var nativeTransition: Task<Void, Never>?
    private var transitionRevision = 0
    private var requestedCollapse = false
    private var nativeApplier: MenuBarClientCoreVisibilityApplier?
    private var nativeIsCollapsed = false
    private let shelf = MenuBarShelfController()
    private var shelfIcons: [MenuBarShelfIcon] = []
    private var shelfSnapshotValid = false
    private var hoverWork: DispatchWorkItem?
    private var dividerTracking: NSTrackingArea?
    private var shelfInteractionMonitor: Any?
    private var shelfInteractionLocalMonitor: Any?
    private var shelfInteractionActive = false
    private var shelfOpenRevision = 0

    var usesNativeVisibility: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    private override init() {
        let enabled = UserDefaults.standard.bool(forKey: DefaultsKey.menuBarIconCollapserEnabled)
        isEnabled = enabled
        // Start hidden on every app launch. Expansion is a temporary viewing
        // action; carrying it across launches briefly exposes every managed
        // icon before the user asks to see them again.
        isCollapsed = enabled
        autoCollapseDelay = MenuBarIconCollapserSupport.sanitizedDelay(
            UserDefaults.standard.integer(forKey: DefaultsKey.menuBarIconCollapserDelay))
        super.init()
        revealMode = MenuBarRevealMode(rawValue: defaults.string(forKey: DefaultsKey.menuBarRevealMode) ?? "") ?? .menuBar
        expandOnHover = defaults.bool(forKey: DefaultsKey.menuBarShelfHover)
        showShelfNames = defaults.object(forKey: DefaultsKey.menuBarShelfShowNames) as? Bool ?? true
        shelf.onClose = { [weak self] in self?.isShelfShown = false }
        shelf.onSelect = { [weak self] target in self?.activateShelfTarget(target) }
        shelf.onSettings = { [weak self] in
            self?.shelf.close()
            SettingsRouter.shared.page = .menuBarIcons
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.shelf.close()
                self?.shelfIcons = []
                self?.shelfSnapshotValid = false
                self?.shelfOpenRevision += 1
            }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.shelfSnapshotValid = false
            }
        }
    }

    func attach(to mainStatusItem: NSStatusItem) {
        self.mainStatusItem = mainStatusItem
        guard AppFeature.menuBarIcons.isAvailable, isEnabled else { return }
        startupCollapseWork?.cancel()
        let shouldCollapseAfterPlacement = isCollapsed
        // A newly restored status item does not have a trustworthy frame yet.
        // Keep the divider at its ordinary width until AppKit has restored both
        // saved positions; expanding it to 10,000 points first moves the very
        // frame used by the safety check and makes a cold launch look unsafe.
        if shouldCollapseAfterPlacement { isCollapsed = false }
        installDividerIfNeeded()
        applyAppearance()
        if shouldCollapseAfterPlacement {
            scheduleStartupCollapse(attemptsLeft: 20)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshPlacement()
                self?.scheduleAutoCollapse()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard AppFeature.menuBarIcons.isAvailable else { return }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.menuBarIconCollapserEnabled)
        placementError = false
        if enabled {
            isCollapsed = false
            defaults.set(false, forKey: DefaultsKey.menuBarIconsCollapsed)
            installDividerIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.refreshPlacement()
                self?.scheduleAutoCollapse()
            }
        } else {
            removeDivider()
        }
    }

    func toggle() {
        if revealMode == .shelf && usesNativeVisibility {
            if isShelfShown { shelf.close() } else { showShelf() }
            return
        }
        setCollapsed(!(isTransitioning ? requestedCollapse : isCollapsed))
    }

    func reveal() {
        if revealMode == .shelf && usesNativeVisibility { toggle() }
        else { setCollapsed(false) }
    }

    func setCollapsed(_ collapsed: Bool) {
        guard AppFeature.menuBarIcons.isAvailable, isEnabled else { return }
        shelf.close()
        startupCollapseWork?.cancel()
        startupCollapseWork = nil
        installDividerIfNeeded()
        if usesNativeVisibility {
            requestNativeCollapse(collapsed)
            return
        }
        refreshPlacement()
        if collapsed && !placementIsSafe {
            placementError = true
            isCollapsed = false
            defaults.set(false, forKey: DefaultsKey.menuBarIconsCollapsed)
            applyAppearance()
            return
        }
        placementError = false
        isCollapsed = collapsed
        defaults.set(collapsed, forKey: DefaultsKey.menuBarIconsCollapsed)
        applyAppearance()
        if collapsed {
            autoCollapseTimer?.invalidate()
            autoCollapseTimer = nil
        } else {
            scheduleAutoCollapse()
        }
    }

    func setAutoCollapseDelay(_ seconds: Int) {
        let sanitized = MenuBarIconCollapserSupport.sanitizedDelay(seconds)
        autoCollapseDelay = sanitized
        shelf.updateDelay(sanitized)
        defaults.set(sanitized, forKey: DefaultsKey.menuBarIconCollapserDelay)
        scheduleAutoCollapse()
    }

    func refreshPlacement() {
        placementIsSafe = MenuBarIconCollapserSupport.hasSafePlacement(
            mainFrame: screenFrame(of: mainStatusItem),
            dividerFrame: screenFrame(of: dividerItem))
        if placementIsSafe { placementError = false }
    }

    /// Feature Hub binding. Uninstalling expands immediately and removes the
    /// divider without deleting its configuration; reinstalling restores it.
    func syncWithFeatures() {
        guard AppFeature.menuBarIcons.isAvailable else {
            removeDivider(preservingPreference: true)
            return
        }
        isEnabled = defaults.bool(forKey: DefaultsKey.menuBarIconCollapserEnabled)
        guard isEnabled else {
            removeDivider(preservingPreference: true)
            return
        }
        installDividerIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.refreshPlacement()
            self?.scheduleAutoCollapse()
        }
    }

    private func installDividerIfNeeded() {
        guard dividerItem == nil else { return }
        // Thaw materializes the underlying WindowServer item at a nonzero
        // seed length before applying the section's width.
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = "VorssaintMenuBarIconDivider"
        item.behavior = []
        item.isVisible = true
        dividerItem = item
        if let button = item.button {
            if let content = button.window?.contentView {
                dividerConstraint = content.constraintsAffectingLayout(for: .horizontal)
                    .first { $0.secondItem === button.superview }
                button.centerYAnchor.constraint(equalTo: content.centerYAnchor).isActive = true
            }
            button.target = self
            button.action = #selector(dividerClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = MenuBarIconCollapserStrings.current.dividerTooltip
            let tracking = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            button.addTrackingArea(tracking)
            dividerTracking = tracking
        }
        applyAppearance()
    }

    private func removeDivider(preservingPreference: Bool = false) {
        shelfOpenRevision += 1
        shelf.close()
        hoverWork?.cancel()
        endShelfInteraction()
        shelfIcons = []
        shelfSnapshotValid = false
        if let tracking = dividerTracking { dividerItem?.button?.removeTrackingArea(tracking) }
        dividerTracking = nil
        if usesNativeVisibility { requestNativeCollapse(false) }
        startupCollapseWork?.cancel()
        startupCollapseWork = nil
        if isCollapsed {
            dividerItem?.length = NSStatusItem.squareLength
        }
        if let dividerItem { NSStatusBar.system.removeStatusItem(dividerItem) }
        dividerItem = nil
        dividerConstraint = nil
        isCollapsed = false
        placementIsSafe = false
        placementError = false
        defaults.set(false, forKey: DefaultsKey.menuBarIconsCollapsed)
        if !preservingPreference { isEnabled = false }
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
    }

    private func applyAppearance() {
        guard let dividerItem, let button = dividerItem.button else { return }
        // Follow Thaw's hidden section: keep the layout constraint active,
        // expand the boundary, and make its button invisible/noninteractive.
        // The normal main status item remains the recovery control (right click).
        dividerConstraint?.isActive = true
        dividerItem.length = isCollapsed && !usesNativeVisibility
            ? MenuBarIconCollapserSupport.collapsedLength
            : NSStatusItem.squareLength
        button.isEnabled = usesNativeVisibility || !isCollapsed
        button.alphaValue = isCollapsed && !usesNativeVisibility ? 0 : 1
        button.isHighlighted = false
        button.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right.2" : "chevron.left.2",
                               accessibilityDescription: MenuBarIconCollapserStrings.current.dividerTooltip)
        button.image?.isTemplate = true
        button.toolTip = MenuBarIconCollapserStrings.current.dividerTooltip
    }

    private func scheduleStartupCollapse(attemptsLeft: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.startupCollapseWork = nil
            self.refreshPlacement()
            if self.placementIsSafe {
                self.setCollapsed(true)
            } else if attemptsLeft > 1 {
                self.scheduleStartupCollapse(attemptsLeft: attemptsLeft - 1)
            }
        }
        startupCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @objc private func dividerClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            if !isCollapsed { setCollapsed(true) }
        } else {
            toggle()
        }
    }

    private func scheduleAutoCollapse() {
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
        guard isEnabled, !isCollapsed, !isTransitioning, !shelfInteractionActive, autoCollapseDelay > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(autoCollapseDelay), repeats: false) { [weak self] _ in
            self?.setCollapsed(true)
        }
        timer.tolerance = min(1, TimeInterval(autoCollapseDelay) / 5)
        RunLoop.main.add(timer, forMode: .common)
        autoCollapseTimer = timer
    }

    private func screenFrame(of item: NSStatusItem?) -> CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Queue transitions so disabling/uninstalling while activation is pending
    /// always releases the assertion afterwards. Stale completions never change UI.
    private func requestNativeCollapse(_ collapsed: Bool) {
        transitionRevision += 1
        let revision = transitionRevision
        requestedCollapse = collapsed
        isTransitioning = true
        operationError = nil
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
        let previous = nativeTransition
        nativeTransition = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, revision == self.transitionRevision else { return }
            if self.nativeApplier == nil {
                self.nativeApplier = MenuBarClientCoreVisibilityApplier(
                    bridge: MenuBarClientCoreBridgeAdapter())
            }
            guard let applier = self.nativeApplier else { return }
            do {
                if collapsed && !self.nativeIsCollapsed {
                    try applier.validateAvailability()
                    self.refreshPlacement()
                    guard self.placementIsSafe else {
                        throw MenuBarIconHidingError.invalidMarkerPosition
                    }
                    let source = self.shelfSource()
                    let resolver = AXMenuBarVisibleItemResolver(
                        markerScreenX: { self.screenFrame(of: self.dividerItem)?.midX },
                        mainItemScreenX: { self.screenFrame(of: self.mainStatusItem)?.midX },
                        ownBundleIdentifier: { Bundle.main.bundleIdentifier },
                        source: source)
                    let allowed = try resolver.itemsToKeepVisible()
                    // Snapshot while visible. A failed preview must not break hiding.
                    let targets = try? source.shelfTargets(hiddenBy: allowed,
                        markerX: self.screenFrame(of: self.dividerItem)?.midX ?? .nan)
                    self.shelfSnapshotValid = targets != nil
                    self.shelfIcons = self.makeShelfIcons(targets ?? [])
                    guard revision == self.transitionRevision else { return }
                    try await applier.applyCollapse(allowing: allowed)
                    self.nativeIsCollapsed = true
                } else if !collapsed {
                    await applier.applyExpansion()
                    self.nativeIsCollapsed = false
                }
                guard revision == self.transitionRevision else { return }
                self.isCollapsed = collapsed
                self.placementError = false
                self.defaults.set(collapsed, forKey: DefaultsKey.menuBarIconsCollapsed)
            } catch {
                await applier.applyExpansion()
                self.nativeIsCollapsed = false
                guard revision == self.transitionRevision else { return }
                self.isCollapsed = false
                self.defaults.set(false, forKey: DefaultsKey.menuBarIconsCollapsed)
                self.placementError = (error as? MenuBarIconHidingError) == .invalidMarkerPosition
                self.operationError = MenuBarIconCollapserStrings.nativeError(error)
                NSLog("Menu bar collapse failed: %@", String(describing: error))
            }
            self.isTransitioning = false
            self.applyAppearance()
            // A failure requires explicit retry; do not repeatedly prompt for AX.
            if self.operationError == nil { self.scheduleAutoCollapse() }
        }
    }

    @MainActor func shutdown() {
        shelfOpenRevision += 1
        shelf.close()
        hoverWork?.cancel()
        endShelfInteraction()
        transitionRevision += 1
        startupCollapseWork?.cancel()
        autoCollapseTimer?.invalidate()
        nativeApplier?.invalidateSynchronously()
    }

    func setRevealMode(_ mode: MenuBarRevealMode) {
        guard mode != .shelf || usesNativeVisibility else { return }
        shelfOpenRevision += 1
        shelf.close()
        endShelfInteraction()
        revealMode = mode
        if mode == .shelf { shelfSnapshotValid = false }
        defaults.set(mode.rawValue, forKey: DefaultsKey.menuBarRevealMode)
        scheduleAutoCollapse()
    }

    func setExpandOnHover(_ enabled: Bool) {
        expandOnHover = enabled
        defaults.set(enabled, forKey: DefaultsKey.menuBarShelfHover)
        if !enabled { hoverWork?.cancel() }
    }

    func setShowShelfNames(_ enabled: Bool) {
        showShelfNames = enabled
        defaults.set(enabled, forKey: DefaultsKey.menuBarShelfShowNames)
        shelf.close()
    }

    @objc private func mouseEntered(_ event: NSEvent) {
        guard isEnabled, revealMode == .shelf, expandOnHover, !shelfInteractionActive else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.screenFrame(of: self.dividerItem)?.contains(NSEvent.mouseLocation) == true else { return }
            if !self.isShelfShown { self.showShelf() }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @objc private func mouseExited(_ event: NSEvent) { hoverWork?.cancel() }

    func showShelf() {
        guard isEnabled, usesNativeVisibility, AppFeature.menuBarIcons.isAvailable else { return }
        shelfOpenRevision += 1
        let revision = shelfOpenRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isTransitioning { await self.nativeTransition?.value }
            guard revision == self.shelfOpenRevision else { return }
            if !self.shelfSnapshotValid && self.nativeIsCollapsed {
                self.setCollapsed(false)
                await self.nativeTransition?.value
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard revision == self.shelfOpenRevision, self.isEnabled else { return }
            if !self.nativeIsCollapsed {
                self.setCollapsed(true)
                await self.nativeTransition?.value
            }
            guard revision == self.shelfOpenRevision, self.isEnabled, self.nativeIsCollapsed,
                  let anchor = self.screenFrame(of: self.dividerItem),
                  let screen = self.dividerItem?.button?.window?.screen else { return }
            guard self.shelfSnapshotValid else {
                self.operationError = MenuBarShelfStrings.text("暂时无法读取隐藏图标，请展开原菜单栏后重试。", "Could not read hidden icons. Reveal the menu bar and retry.")
                return
            }
            self.shelf.show(icons: self.shelfIcons, anchor: anchor, screen: screen,
                            delay: self.autoCollapseDelay, showNames: self.showShelfNames)
            self.isShelfShown = true
        }
    }

    @MainActor private func shelfSource() -> SystemAXMenuBarSource {
        SystemAXMenuBarSource(preferredDisplayBounds: { [weak self] in
            guard let screen = self?.dividerItem?.button?.window?.screen else { return .null }
            return CGDisplayBounds(screen.displayID)
        })
    }

    @MainActor private func makeShelfIcons(_ targets: [MenuBarShelfTarget]) -> [MenuBarShelfIcon] {
        targets.map { target in
            MenuBarShelfIcon(target: target, image: MenuBarShelfIconProvider.image(
                bundleIdentifier: target.bundleIdentifier, systemIdentifier: target.systemIdentifier))
        }
    }

    private func activateShelfTarget(_ target: MenuBarShelfTarget) {
        shelfOpenRevision += 1
        let revision = shelfOpenRevision
        shelf.close()
        endShelfInteraction()
        shelfInteractionActive = true
        setCollapsed(false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.nativeTransition?.value
            guard self.isEnabled, !self.nativeIsCollapsed, self.shelfInteractionActive else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard revision == self.shelfOpenRevision, self.isEnabled,
                  self.shelfInteractionActive, !self.nativeIsCollapsed else { return }
            do {
                try self.shelfSource().pressShelfTarget(target)
                self.watchShelfInteraction()
            } catch {
                self.operationError = MenuBarShelfStrings.text(
                    "无法自动打开此图标，已在菜单栏展开，请直接点击原图标。",
                    "Could not activate this icon. It is revealed in the menu bar; click it directly.")
                // Leave it visible for manual recovery; never guess a coordinate.
                self.watchShelfInteraction()
            }
        }
    }

    private func watchShelfInteraction() {
        let revision = shelfOpenRevision
        // Mouse-up runs after the selected menu action, not before it.
        let finish: (NSEvent) -> Void = { [weak self] event in
            guard event.type != .keyUp || event.keyCode == 53 || event.keyCode == 36 else { return }
            guard let self else { return }
            self.endShelfInteraction()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.isEnabled, self.revealMode == .shelf,
                      revision == self.shelfOpenRevision else { return }
                self.setCollapsed(true)
            }
        }
        shelfInteractionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyUp], handler: finish)
        shelfInteractionLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyUp]) { event in
            finish(event)
            return event
        }
    }

    private func endShelfInteraction() {
        if let shelfInteractionMonitor { NSEvent.removeMonitor(shelfInteractionMonitor) }
        if let shelfInteractionLocalMonitor { NSEvent.removeMonitor(shelfInteractionLocalMonitor) }
        shelfInteractionMonitor = nil
        shelfInteractionLocalMonitor = nil
        shelfInteractionActive = false
    }
}
