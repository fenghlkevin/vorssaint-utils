// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import SwiftUI

final class BatteryStatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private(set) var statusItem: NSStatusItem
    private let popover = NSPopover()
    private var detailWindow: NSWindow?
    private var measuredPopoverHeight: CGFloat?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: 42)
        super.init()
        statusItem.autosaveName = "VorssaintBatteryStatusItem"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openMenu)
        popover.behavior = .transient
        popover.delegate = self
        // AppKit owns the viewport size. Do not let the hosting controller's
        // intrinsic document height resize the popover beyond the display.
        let hosting = NSHostingController(rootView: makePanel())
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        AppAppearanceController.shared.follow(panel: popover)
        BatteryPanelModel.shared.objectWillChange
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        BatteryManagementService.shared.objectWillChange
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name("VorssaintShowBatteryPanel"))
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                if self.statusItem.isVisible, self.statusItem.button?.window != nil {
                    if !self.popover.isShown { self.openMenu() }
                } else {
                    self.showDetailWindow()
                }
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.popover.performClose(nil)
            }.store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        let visible = AppFeature.batteryManagement.isAvailable &&
            (UserDefaults.standard.object(forKey: DefaultsKey.batteryManagementMenuBarIcon) as? Bool ?? true)
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
        if !visible && popover.isShown { popover.performClose(nil) }
        guard let button = statusItem.button else { return }
        let model = BatteryPanelModel.shared
        let batteryService = BatteryManagementService.shared
        let badge: String
        let activelyDischarging = batteryService.mode == .discharging
        let ordinarilyDischarging = !model.reading.externalConnected && !activelyDischarging
        if batteryService.lastError != nil { badge = "exclamationmark" }
        else if activelyDischarging { badge = "arrow.down" }
        else if model.reading.isCharging { badge = "bolt.fill" }
        else if ordinarilyDischarging { badge = "" }
        else { badge = "powerplug.portrait.fill" }
        let defaults = UserDefaults.standard
        let monochrome = defaults.object(forKey: DefaultsKey.batteryIconMonochrome) as? Bool ?? true
        let dynamic = defaults.string(forKey: DefaultsKey.batteryIconStyle) != "simple"
        if defaults.bool(forKey: DefaultsKey.batteryIconRemainingTime), !model.reading.externalConnected,
           let seconds = model.reading.timeRemainingSeconds, seconds.isFinite, seconds > 0, seconds < 604800 {
            let minutes = Int(seconds / 60)
            button.title = " \(minutes / 60):\(String(format: "%02d", minutes % 60))"
        } else { button.title = "" }
        statusItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        button.image = Self.icon(percent: model.reading.chargePercent, badge: badge,
                                 monochrome: monochrome && !ordinarilyDischarging,
                                 dynamic: dynamic)
        button.toolTip = "电池 \(model.reading.chargePercent.map { "\($0)%" } ?? "—") · \(model.stateText)"
        if let error = BatteryManagementService.shared.lastError { button.toolTip = (button.toolTip ?? "") + " · " + error }
        button.setAccessibilityLabel(button.toolTip)
    }

    static func icon(percent: Int?, badge: String, monochrome: Bool = true, dynamic: Bool = true) -> NSImage {
        BatteryMenuIcon.draw(percent: percent, badge: badge, monochrome: monochrome, dynamic: dynamic)
    }

    @objc private func openMenu() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let size = BatteryPanelLayout.viewport(visibleFrame: screen.visibleFrame, anchorBottom: anchor.minY)
            let renderSize = CGSize(width: size.width,
                                    height: min(size.height, measuredPopoverHeight ?? size.height))
            if let hosting = popover.contentViewController as? NSHostingController<BatteryManagementPanel> {
                hosting.rootView = makePanel(viewport: renderSize)
                hosting.view.setFrameSize(renderSize)
            }
            popover.contentSize = renderSize
            BatteryPanelModel.shared.setVisible(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showDetailWindow() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = screen.map { BatteryPanelLayout.viewport(visibleFrame: $0.visibleFrame,
                                                           anchorBottom: $0.visibleFrame.maxY - 28) }
            ?? CGSize(width: 320, height: 820)
        if detailWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "电池管理"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: makePanel(viewport: size))
            window.center()
            detailWindow = window
        }
        if let hosting = detailWindow?.contentView as? NSHostingView<BatteryManagementPanel> {
            hosting.rootView = makePanel(viewport: size)
            detailWindow?.setContentSize(size)
        }
        BatteryPanelModel.shared.setVisible(true)
        detailWindow?.makeKeyAndOrderFront(nil)
    }

    private func makePanel(viewport: CGSize = CGSize(width: 320, height: 820)) -> BatteryManagementPanel {
        BatteryManagementPanel(viewport: viewport) { [weak self] in
            self?.popover.performClose(nil)
            SettingsRouter.shared.page = .batteryManagement
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
        } contentHeightChanged: { [weak self] height in
            guard let self else { return }
            self.measuredPopoverHeight = height
            guard self.popover.isShown else { return }
            let target = CGSize(width: viewport.width, height: max(1, height))
            guard abs(self.popover.contentSize.height - target.height) > 1 else { return }
            if let hosting = self.popover.contentViewController as? NSHostingController<BatteryManagementPanel> {
                hosting.rootView = self.makePanel(viewport: target)
                hosting.view.setFrameSize(target)
            }
            self.popover.contentSize = target
        }
    }

    func popoverDidClose(_ notification: Notification) {
        BatteryPanelModel.shared.setVisible(detailWindow?.isVisible == true)
    }
    func windowWillClose(_ notification: Notification) {
        BatteryPanelModel.shared.setVisible(popover.isShown)
    }
    deinit { NSStatusBar.system.removeStatusItem(statusItem) }
}
