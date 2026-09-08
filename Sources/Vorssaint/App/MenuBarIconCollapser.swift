// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// A public-API-only menu bar divider. Expanding its status-item length uses
/// ordinary menu bar layout pressure to move the items on its left out of the
/// visible area. The divider and Vorssaint stay visible on its right, so the
/// user always has a way back.
final class MenuBarIconCollapser: NSObject, ObservableObject {
    static let shared = MenuBarIconCollapser()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isCollapsed: Bool
    @Published private(set) var placementIsSafe = false
    @Published private(set) var placementError = false
    @Published private(set) var autoCollapseDelay: Int

    private weak var mainStatusItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private let defaults = UserDefaults.standard
    private var autoCollapseTimer: Timer?
    private var startupCollapseWork: DispatchWorkItem?

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
        setCollapsed(!isCollapsed)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard AppFeature.menuBarIcons.isAvailable, isEnabled else { return }
        startupCollapseWork?.cancel()
        startupCollapseWork = nil
        installDividerIfNeeded()
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
        defaults.set(sanitized, forKey: DefaultsKey.menuBarIconCollapserDelay)
        scheduleAutoCollapse()
    }

    func refreshPlacement() {
        placementIsSafe = MenuBarIconCollapserSupport.hasSafePlacement(
            mainFrame: mainStatusItem?.button?.window?.frame,
            dividerFrame: dividerItem?.button?.window?.frame)
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "VorssaintMenuBarIconDivider"
        item.behavior = []
        item.isVisible = true
        dividerItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(dividerClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = MenuBarIconCollapserStrings.current.dividerTooltip
        }
        applyAppearance()
    }

    private func removeDivider(preservingPreference: Bool = false) {
        startupCollapseWork?.cancel()
        startupCollapseWork = nil
        if isCollapsed {
            dividerItem?.length = NSStatusItem.squareLength
        }
        if let dividerItem { NSStatusBar.system.removeStatusItem(dividerItem) }
        dividerItem = nil
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
        dividerItem.length = isCollapsed
            ? MenuBarIconCollapserSupport.collapsedLength
            : NSStatusItem.squareLength
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
        guard isEnabled, !isCollapsed, autoCollapseDelay > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(autoCollapseDelay), repeats: false) { [weak self] _ in
            self?.setCollapsed(true)
        }
        timer.tolerance = min(1, TimeInterval(autoCollapseDelay) / 5)
        RunLoop.main.add(timer, forMode: .common)
        autoCollapseTimer = timer
    }
}
