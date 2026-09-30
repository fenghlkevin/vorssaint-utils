// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import OSLog

/// A nonactivating wheel can hold keyboard focus without owning application
/// activation. Ask Launch Services to foreground the app, then raise the exact
/// window; do not assume closing the wheel transferred activation rights.
enum RadialSwitcherActivation {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vorssaint.utils",
                                    category: "RadialActivation")
    private static var generation = 0

    static func cancel() { generation += 1 }

    static func activate(app: NSRunningApplication, window: SwitcherItem?, sourcePID: pid_t?) {
        generation += 1
        let ticket = generation
        let pid = app.processIdentifier
        let sourceWindowID = sourcePID.flatMap { WindowActivator.focusedWindowID(for: $0) }
        log.notice("requested target=\(pid) window=\(window?.windowID ?? 0) source=\(sourcePID ?? 0)")
        // Let orderOut finish releasing the panel's key focus before requesting
        // foreground activation. This also avoids focus restoration racing it.
        DispatchQueue.main.async {
            guard ticket == generation, !app.isTerminated else { return }
            app.unhide()
            NSApp.yieldActivation(to: app)
            guard let url = app.bundleURL else {
                focus(app: app, window: window, sourcePID: sourcePID, sourceWindowID: sourceWindowID)
                verify(pid: pid, window: window, ticket: ticket)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, error in
                DispatchQueue.main.async {
                    guard ticket == generation, !app.isTerminated else { return }
                    if let error { log.error("foreground request failed: \(error.localizedDescription, privacy: .public)") }
                    guard running == nil || running?.processIdentifier == pid else { return }
                    focus(app: app, window: window, sourcePID: sourcePID, sourceWindowID: sourceWindowID)
                    verify(pid: pid, window: window, ticket: ticket)
                }
            }
        }
    }

    private static func focus(app: NSRunningApplication, window: SwitcherItem?,
                              sourcePID: pid_t?, sourceWindowID: CGWindowID?) {
        let item = window ?? .appOnly(appName: app.localizedName ?? "App", pid: app.processIdentifier)
        WindowActivator.activate(item, sourcePID: sourcePID, sourceWindowID: sourceWindowID)
    }

    private static func verify(pid: pid_t, window: SwitcherItem?, ticket: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard ticket == generation else { return }
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let focusedWindow = WindowActivator.focusedWindowID(for: pid) ?? 0
            log.notice("result target=\(pid) foreground=\(foreground) expectedWindow=\(window?.windowID ?? 0) focusedWindow=\(focusedWindow)")
        }
    }
}
