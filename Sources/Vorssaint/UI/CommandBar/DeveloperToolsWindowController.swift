// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// A small built-in app launched from search. The command bar can close or
/// reopen independently without discarding the editor's in-progress content.
final class DeveloperToolsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DeveloperToolsWindowController()

    let session = CommandBarDeveloperSession()
    private var keyMonitor: Any?
    private var titleObserver: AnyCancellable?

    private init() {
        super.init(window: nil)
        titleObserver = session.$tool.sink { [weak self] tool in
            self?.window?.title = tool.launcherTitle
        }
    }

    required init?(coder: NSCoder) { nil }

    func show(tool: CommandBarDeveloperTool, input: String = "") {
        guard CommandBarBuiltinSettings.isEnabled(tool) else { return }
        let alreadyOpen = window?.isVisible == true || window?.isMiniaturized == true
        if !alreadyOpen || !input.isEmpty {
            session.open(tool, input: input)
        } else if session.tool != tool {
            // Switching an operation keeps the text already being edited.
            session.tool = tool
        }
        if window == nil {
            let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            editor.isReleasedWhenClosed = false
            editor.contentMinSize = NSSize(width: 640, height: 500)
            editor.delegate = self
            editor.contentViewController = NSHostingController(rootView: CommandBarDeveloperView(session: session))
            editor.center()
            window = editor
        }
        guard let window else { return }
        window.title = tool.launcherTitle
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        installKeyboardMonitor(for: window)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        session.reset()
    }

    private func installKeyboardMonitor(for window: NSWindow) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == [.shift], [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
                self.session.run()
                return nil
            }
            if modifiers == [.command], Int(event.keyCode) == kVK_ANSI_W {
                window.performClose(nil)
                return nil
            }
            return event
        }
    }
}
