// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Focus verification design adapted from LumaRing (MIT):
// https://github.com/potatoQi/LumaRing/blob/main/Sources/LumaRing/ActionExecutor.swift

import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum RadialActionExecutor {
    struct Focus {
        let pid: pid_t
        let launchDate: Date
        let window: AXUIElement
        let element: AXUIElement?
    }

    private static func read(_ element: AXUIElement, _ key: String) -> (CFTypeRef?, AXError) {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return (value, result)
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func capture(for app: NSRunningApplication) -> Focus? {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let launchDate = app.launchDate else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        let (rawWindow, windowError) = read(axApp, kAXFocusedWindowAttribute as String)
        guard windowError == .success, let window = axElement(rawWindow) else { return nil }
        let (rawControl, controlError) = read(axApp, kAXFocusedUIElementAttribute as String)
        guard controlError == .success || controlError == .noValue
                || controlError == .attributeUnsupported else { return nil }
        let control = controlError == .success ? axElement(rawControl) : nil
        if controlError == .success && control == nil { return nil }
        return Focus(pid: pid, launchDate: launchDate, window: window, element: control)
    }

    private static func stillFocused(_ focus: Focus) -> Bool {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSRunningApplication(processIdentifier: focus.pid),
              app.launchDate == focus.launchDate,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.pid else { return false }
        let axApp = AXUIElementCreateApplication(focus.pid)
        let (windowRaw, windowError) = read(axApp, kAXFocusedWindowAttribute as String)
        guard windowError == .success, let window = axElement(windowRaw),
              CFEqual(window, focus.window) else { return false }
        if let element = focus.element {
            let (controlRaw, controlError) = read(axApp, kAXFocusedUIElementAttribute as String)
            guard controlError == .success, let control = axElement(controlRaw),
                  CFEqual(control, element) else { return false }
        }
        return true
    }

    static func execute(_ shortcut: GlobalShortcut, focus: Focus) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            while !modifiersReleased() && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard modifiersReleased(), stillFocused(focus),
                  let events = events(for: shortcut), modifiersReleased() else {
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            for event in events { event.postToPid(focus.pid) }
        }
    }

    private static func modifiersReleased() -> Bool {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
            .isEmpty
    }

    private static func events(for shortcut: GlobalShortcut) -> [CGEvent]? {
        guard let keyCode = CGKeyCode(exactly: shortcut.keyCode),
              let source = CGEventSource(stateID: .privateState) else { return nil }
        let keys: [(GlobalShortcutModifiers, CGKeyCode, CGEventFlags)] = [
            (.control, CGKeyCode(kVK_Control), .maskControl),
            (.option, CGKeyCode(kVK_Option), .maskAlternate),
            (.shift, CGKeyCode(kVK_Shift), .maskShift),
            (.command, CGKeyCode(kVK_Command), .maskCommand),
        ].filter { shortcut.modifiers.contains($0.0) }
        var flags: CGEventFlags = []
        var result: [CGEvent] = []
        func add(_ key: CGKeyCode, down: Bool) -> Bool {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            else { return false }
            event.flags = flags
            result.append(event)
            return true
        }
        for (_, key, flag) in keys { flags.insert(flag); if !add(key, down: true) { return nil } }
        guard add(keyCode, down: true), add(keyCode, down: false) else { return nil }
        for (_, key, flag) in keys.reversed() {
            flags.remove(flag)
            if !add(key, down: false) { return nil }
        }
        return result
    }
}
