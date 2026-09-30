// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices

struct AwayLockReturnUnlock {
    var armed = false
    private var lastAttempt: Date?
    mutating func consume(enabled: Bool, locked: Bool, now: Date) -> Bool {
        let eligible = armed
        armed = false
        guard eligible, enabled, locked,
              lastAttempt.map({ now.timeIntervalSince($0) >= 120 }) ?? true else { return false }
        lastAttempt = now
        return true
    }
}

@MainActor
enum AwayLockAutoUnlock {
    enum Result: Equatable {
        case unlocked, cancelled
        case failed(String)
    }

    /// Wait for normal authentication first, then make at most one password submission.
    static func run(
        allowed: @MainActor () -> Bool,
        locked: @MainActor () -> Bool? = AwayLockScreenControl.currentSessionLocked,
        password: @MainActor () throws -> String? = AwayLockPassword.read,
        prepare: @MainActor () -> Bool = showPasswordField,
        submit: @MainActor (String) -> Bool = submitPassword,
        wait: @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }
    ) async -> Result {
        for _ in 0..<12 { // Allow Apple Watch / manual authentication to finish first.
            guard !Task.isCancelled, allowed() else { return .cancelled }
            guard let isLocked = locked() else { return .failed("无法确认锁屏状态，已跳过密码输入") }
            if !isLocked { return .unlocked }
            do { try await wait() } catch { return .cancelled }
        }
        guard !Task.isCancelled, allowed(), locked() == true else { return .cancelled }
        guard prepare() else { return .failed("无法定位系统登录窗口，请手动解锁") }
        for _ in 0..<4 {
            do { try await wait() } catch { return .cancelled }
            guard !Task.isCancelled, allowed(), locked() == true else { return .cancelled }
        }
        do {
            guard let secret = try password(), !secret.isEmpty else { return .failed("未设置登录密码，请在设置中配置") }
            guard !Task.isCancelled, allowed(), locked() == true else { return .cancelled }
            guard submit(secret) else { return .failed("未确认系统密码输入框，已停止自动输入；请手动解锁") }
        } catch { return .failed("无法读取钥匙串中的登录密码，请在设置中重新保存") }
        for _ in 0..<32 {
            do { try await wait() } catch { return .cancelled }
            guard !Task.isCancelled, allowed() else { return .cancelled }
            if locked() == false { return .unlocked }
        }
        return .failed("未确认解锁成功，不再重试；请手动解锁并检查保存的密码")
    }

    private static func loginWindow() -> NSRunningApplication? {
        guard AXIsProcessTrusted(), AwayLockScreenControl.currentSessionLocked() == true,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["kCGSSessionOnConsoleKey"] as? Bool == true,
              (session["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == getuid() else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow")
            .first { !$0.isTerminated }
    }

    private static func focusedPasswordField(pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let field = unsafeBitCast(value, to: AXUIElement.self)
        var owner: pid_t = 0
        var subrole: CFTypeRef?
        guard AXUIElementGetPid(field, &owner) == .success, owner == pid,
              AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String == "AXSecureTextField" else { return nil }
        return field
    }

    private static func key(_ code: CGKeyCode, pid: pid_t, flags: CGEventFlags = [], text: [UniChar]? = nil) -> Bool {
        guard AwayLockScreenControl.currentSessionLocked() == true,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags; up.flags = flags
        if let text { down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
        // Target loginwindow only: never send a password to the foreground desktop app.
        down.postToPid(pid); up.postToPid(pid)
        return true
    }

    private static func showPasswordField() -> Bool {
        let displays = AwayLockScreenControl.displaySleepCounts()
        guard displays.online > displays.asleep, let app = loginWindow() else { return false }
        return key(56, pid: app.processIdentifier) // Shift reveals the password field without typing.
    }

    private static func submitPassword(_ password: String) -> Bool {
        guard let app = loginWindow(), let field = focusedPasswordField(pid: app.processIdentifier) else { return false }
        // Do not append to a password the user has already begun typing.
        var existing: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &existing) == .success,
              let current = existing as? String, current.isEmpty else { return false }
        let units = Array(password.utf16)
        for start in stride(from: 0, to: units.count, by: 20) {
            guard loginWindow()?.processIdentifier == app.processIdentifier,
                  focusedPasswordField(pid: app.processIdentifier) != nil,
                  key(0, pid: app.processIdentifier, text: Array(units[start..<min(start + 20, units.count)])) else { return false }
        }
        guard focusedPasswordField(pid: app.processIdentifier) != nil else { return false }
        return key(36, pid: app.processIdentifier)
    }
}
