// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

enum RadialSwitcherWindowCreator {
    static func create(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID else { return }
            if RadialBrowserEvents.supports(bundleID),
               RadialBrowserEvents.permission(pid: pid, ask: false) == noErr {
                do {
                    try RadialBrowserEvents(pid: pid, budget: 3).newWindow()
                    DispatchQueue.main.async { app.activate() }
                    return
                } catch {
                    DispatchQueue.main.async { NSSound.beep() }
                    return
                }
            }
            guard AXIsProcessTrusted(), let item = findNewWindowMenuItem(pid: pid) else {
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            DispatchQueue.main.async {
                guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID else { return }
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if AXUIElementPerformAction(item, kAXPressAction as CFString) != .success {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    private static func findNewWindowMenuItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        var queue = [raw as! AXUIElement]
        let titles: Set<String> = ["New Window", "新建窗口", "新建访达窗口", "新建終端機視窗", "新建终端窗口"]
        var visited = 0
        while !queue.isEmpty && visited < 280 {
            let item = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(item, 0.08)
            var roleValue: CFTypeRef?
            var titleValue: CFTypeRef?
            var enabledValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &roleValue)
            _ = AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleValue)
            _ = AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabledValue)
            if roleValue as? String == kAXMenuItemRole,
               let title = titleValue as? String, titles.contains(title),
               (enabledValue as? NSNumber)?.boolValue != false { return item }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { continue }
            queue.append(contentsOf: list.prefix(40))
        }
        return nil
    }
}
