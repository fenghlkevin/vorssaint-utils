// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Gesture recognizers adapted from LumaRing (MIT), see Resources/LumaRing-LICENSE.txt.

import AppKit
import ApplicationServices
import RadialTrackpadInput

final class RadialTrackpadService: ObservableObject {
    static let shared = RadialTrackpadService()

    @Published private(set) var status = "关闭"
    private var generation: UInt64 = 0
    private var currentConfig: (tap: Int, pinch: Bool)?
    private var paused = false
    private var pinchPID: pid_t?
    private var pinchWindow: AXUIElement?
    private var pinchCompleted = false
    private var pinchSequence = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.paused = true
            self?.stop()
            self?.status = "已暂停"
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.paused = false
            self?.sync()
        })
    }

    func sync(force: Bool = false) {
        let defaults = UserDefaults.standard
        let enabled = AppFeature.radialSwitcher.isAvailable
            && defaults.bool(forKey: DefaultsKey.radialSwitcherEnabled)
        let tap = defaults.integer(forKey: DefaultsKey.radialSwitcherTrackpadTap)
        let pinch = defaults.bool(forKey: DefaultsKey.radialSwitcherPinchMinimize)
        let wanted = enabled && !paused && (tap == 3 || tap == 4 || pinch)
        if !force, wanted, let currentConfig, currentConfig.tap == tap,
           currentConfig.pinch == pinch { return }
        stop()
        guard wanted else {
            status = enabled && paused ? "已暂停" : "关闭"
            return
        }
        let callback: LRTapCallback = { token in
            DispatchQueue.main.async {
                RadialTrackpadService.shared.deliverTap(token)
            }
        }
        let pinchCallback: LRPinchCallback = { token, _, event in
            DispatchQueue.main.async {
                RadialTrackpadService.shared.deliverPinch(token, event: event)
            }
        }
        let result = LRTrackpadStartConfigured(tap == 3 || tap == 4 ? callback : nil,
                                               pinch ? pinchCallback : nil,
                                               UInt32(tap))
        generation = result.devices > 0 ? result.generation : 0
        currentConfig = (tap, pinch)
        status = !result.available ? "此设备不支持" : result.devices == 0 ? "未找到触控板" : "已连接 \(result.devices) 个触控板"
    }

    private func stop() {
        generation = 0
        currentConfig = nil
        pinchSequence += 1
        pinchPID = nil
        pinchWindow = nil
        pinchCompleted = false
        LRTrackpadStop()
    }

    private func deliverTap(_ token: UInt64) {
        guard token == generation, !paused,
              UserDefaults.standard.integer(forKey: DefaultsKey.radialSwitcherTrackpadTap) >= 3 else { return }
        RadialSwitcherService.shared.toggleFromTrackpad()
    }

    private func deliverPinch(_ token: UInt64, event: LRPinchEvent) {
        guard token == generation, !paused,
              UserDefaults.standard.bool(forKey: DefaultsKey.radialSwitcherPinchMinimize) else { return }
        switch event {
        case LRPinchBegan: beginPinch()
        case LRPinchCompleted:
            pinchCompleted = true
            commitPinchIfReady()
        case LRPinchCancelled: cancelPinch()
        default: break
        }
    }

    private func beginPinch() {
        cancelPinch()
        guard AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let sequence = pinchSequence
        pinchPID = pid
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.08)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            let window = result == .success && value.map({ CFGetTypeID($0) == AXUIElementGetTypeID() }) == true
                ? (value as! AXUIElement) : nil
            DispatchQueue.main.async {
                guard self.pinchSequence == sequence, self.pinchPID == pid else { return }
                self.pinchWindow = window
                self.commitPinchIfReady()
            }
        }
    }

    private func commitPinchIfReady() {
        guard pinchCompleted, let pid = pinchPID, let window = pinchWindow,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        cancelPinch()
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementSetMessagingTimeout(window, 0.08)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXWindowRole,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func cancelPinch() {
        pinchSequence += 1
        pinchPID = nil
        pinchWindow = nil
        pinchCompleted = false
    }
}
