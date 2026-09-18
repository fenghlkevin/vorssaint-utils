// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

// Retained SwiftUI content does not necessarily disappear when its window hides.
// Observe the native window so hidden menu panels cannot leave a polling loop on.
struct ProxyVisibilityProbe: NSViewRepresentable {
    let telemetry: ProxyTelemetry
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(telemetry: telemetry) }
    func updateNSView(_ nsView: VisibilityView, context: Context) { nsView.refresh() }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.stop() }
    @MainActor final class VisibilityView: NSView {
        private let telemetry: ProxyTelemetry
        private let id = UUID().uuidString
        private var observers: [NSObjectProtocol] = []
        init(telemetry: ProxyTelemetry) { self.telemetry = telemetry; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        if event.name == NSWindow.willCloseNotification { self.telemetry.setVisible(self.id, false) } else { self.refresh() }
                    }
                })
            }
            refresh()
        }
        func refresh() { telemetry.setVisible(id, window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true) }
        func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers = []; telemetry.setVisible(id, false) }
    }
}

