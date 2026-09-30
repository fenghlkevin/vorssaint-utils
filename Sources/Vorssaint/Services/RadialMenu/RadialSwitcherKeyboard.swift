// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CoreGraphics

/// Runs inside the shared switcher tap. Only lock-protected value state is
/// touched here; UI and Accessibility work always run after the tap returns.
enum RadialSwitcherKeyboard {
    private static let lock = NSLock()
    private static var enabled = false
    private static var shortcut = GlobalShortcut.radialSwitcherDefault
    private static var hold = false
    private static var active = false
    private static var swallowedKeys = Set<Int64>()

    static var needsTap: Bool { lock.withLock { enabled } }

    static func configure(enabled value: Bool, shortcut key: GlobalShortcut, holdToSelect: Bool) {
        lock.withLock {
            enabled = value
            shortcut = key
            hold = holdToSelect || key == .switcherDefault
            if !value { active = false }
        }
    }

    static func cancel() { lock.withLock { active = false } }

    static func route(type: CGEventType, event: CGEvent) -> Bool {
        lock.withLock {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyUp, swallowedKeys.remove(key) != nil { return true }
            guard enabled else { return false }
            if type == .flagsChanged, active, hold,
               !shortcut.requiredModifiersHeld(in: event.flags) {
                active = false
                DispatchQueue.main.async { RadialSwitcherService.shared.commitKeyboardSelection() }
                return false // Other apps still need modifier release events.
            }
            guard type == .keyDown else { return false }
            let reverse = event.flags.contains(.maskShift)
            if shortcut.matches(event: event, allowingExtraShift: true) {
                let first = !active
                active = true
                swallowedKeys.insert(key)
                DispatchQueue.main.async {
                    RadialSwitcherService.shared.keyboardStep(first: first, reverse: reverse)
                }
                return true
            }
            guard active else { return false }
            switch key {
            case 48, 123, 124, 125, 126:
                swallowedKeys.insert(key)
                DispatchQueue.main.async {
                    RadialSwitcherService.shared.keyboardStep(first: false,
                        reverse: key == 123 || key == 126 || (key == 48 && reverse))
                }
            case 53:
                active = false
                swallowedKeys.insert(key)
                DispatchQueue.main.async { RadialSwitcherService.shared.dismiss() }
            case 36, 76:
                active = false
                swallowedKeys.insert(key)
                DispatchQueue.main.async { RadialSwitcherService.shared.commitKeyboardSelection() }
            case 50:
                swallowedKeys.insert(key)
                DispatchQueue.main.async { RadialSwitcherService.shared.openKeyboardChildren() }
            default: return false
            }
            return true
        }
    }
}
