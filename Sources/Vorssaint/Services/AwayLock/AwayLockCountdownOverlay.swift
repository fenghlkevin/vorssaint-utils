// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

@MainActor
private final class AwayLockCountdownOverlayModel: ObservableObject {
    @Published var seconds = 5
    @Published var totalSeconds = 5
}

/// A foreground warning shown immediately before Away Lock locks the Mac.
/// It mirrors AwayLock's all-Spaces, cancellable five-second countdown.
@MainActor
final class AwayLockCountdownOverlay {
    static let shared = AwayLockCountdownOverlay()

    private let model = AwayLockCountdownOverlayModel()
    private var panel: NSPanel?
    private var cancelAction: (() -> Void)?
    private var previewTimer: Timer?

    func show(seconds: Int, cancel: @escaping () -> Void) {
        previewTimer?.invalidate()
        previewTimer = nil
        cancelAction = cancel
        model.seconds = max(1, seconds)
        model.totalSeconds = max(1, seconds)

        let panel = panel ?? makePanel()
        self.panel = panel
        center(panel)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(seconds: Int) {
        model.seconds = max(0, seconds)
    }

    func hide() {
        previewTimer?.invalidate()
        previewTimer = nil
        panel?.orderOut(nil)
        cancelAction = nil
    }

    /// Shows the configured warning without invoking the screen-lock action.
    func preview(seconds: Int) {
        var remaining = max(1, seconds)
        show(seconds: remaining) { [weak self] in self?.hide() }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                remaining -= 1
                guard remaining > 0 else {
                    self.hide()
                    return
                }
                self.update(seconds: remaining)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 190),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: AwayLockCountdownOverlayView(
            model: model,
            cancelAction: { [weak self] in self?.cancelPressed() }
        ))
        return panel
    }

    private func center(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        ))
    }

    private func cancelPressed() {
        let action = cancelAction
        hide()
        action?()
    }
}

private struct AwayLockCountdownOverlayView: View {
    @ObservedObject var model: AwayLockCountdownOverlayModel
    let cancelAction: () -> Void

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.001, Double(model.seconds) / Double(max(1, model.totalSeconds))))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: model.seconds)
                Text("\(model.seconds)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 7) {
                Label("即将自动锁屏", systemImage: "lock.fill")
                    .font(.title3.bold())
                Text("检测到目标蓝牙设备已经离开")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("我还在，取消锁屏", action: cancelAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
        .padding(7)
    }
}
