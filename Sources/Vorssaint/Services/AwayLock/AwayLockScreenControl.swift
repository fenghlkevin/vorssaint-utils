// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
import IOKit.pwr_mgt

/// System shortcut locking and an optional, bounded display wake request.
@MainActor
enum AwayLockScreenControl {
    private static var wakeAssertion: IOPMAssertionID = 0
    private static var wakeRelease: Task<Void, Never>?

    static func displaySleepCounts() -> (online: Int, asleep: Int) {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return (0, 0) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return (0, 0) }
        let displays = ids.prefix(Int(count))
        return (displays.count, displays.filter { CGDisplayIsAsleep($0) != 0 }.count)
    }

    static func wakeDisplayOnce() -> IOReturn {
        releaseWakeRequest()
        let result = IOPMAssertionDeclareUserActivity("Vorssaint Away Lock Return" as CFString,
                                                     kIOPMUserActiveLocal, &wakeAssertion)
        if wakeAssertion != 0 {
            wakeRelease = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                releaseWakeRequest()
            }
        }
        return result
    }

    static func releaseWakeRequest() {
        wakeRelease?.cancel(); wakeRelease = nil
        if wakeAssertion != 0 {
            IOPMAssertionRelease(wakeAssertion)
            wakeAssertion = 0
        }
    }

    enum Result: Equatable {
        case locked
        case failed(String)
    }

    static func lock(
        sessionLocked: @MainActor () -> Bool? = currentSessionLocked,
        sendShortcut: @MainActor () -> Bool = postLockShortcut,
        wait: @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }
    ) async -> Result {
        guard !Task.isCancelled else { return .failed("锁屏请求已取消") }
        guard let locked = sessionLocked() else { return .failed("无法读取系统锁定状态") }
        if locked { return .locked }
        guard sendShortcut() else { return .failed("锁屏快捷键发送失败，请检查辅助功能权限") }
        for _ in 0..<20 {
            do { try await wait() } catch { return .failed("锁屏确认已取消") }
            guard !Task.isCancelled else { return .failed("锁屏确认已取消") }
            if sessionLocked() == true { return .locked }
        }
        return .failed("5 秒内未确认锁屏，请手动按 Control–Command–Q")
    }

    static func currentSessionLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        // The flag may be absent in an unlocked, valid session.
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func postLockShortcut() -> Bool {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else { return false }
        down.flags = [.maskControl, .maskCommand]
        up.flags = [.maskControl, .maskCommand]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
