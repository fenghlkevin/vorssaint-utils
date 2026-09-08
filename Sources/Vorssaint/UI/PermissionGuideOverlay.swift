// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import SwiftUI

/// The floating permission guide: a small non-activating card that appears
/// when a permission request sends the person to System Settings, walks them
/// through the three steps and notices the grant by itself (the app's
/// permission refresh already observes it). The trip to System Settings and
/// back is where most people give up; this card keeps them company.
///
/// Nothing exists while the card is hidden: the window, the hosting view and
/// the Combine subscription are created on show and released on dismiss.
final class PermissionGuideOverlay {
    static let shared = PermissionGuideOverlay()

    enum Kind {
        case accessibility, screenRecording, fullDiskAccess, appManagement

        var permission: AppPermission {
            switch self {
            case .accessibility: return .accessibility
            case .screenRecording: return .screenRecording
            case .fullDiskAccess: return .fullDiskAccess
            case .appManagement: return .appManagement
            }
        }
    }

    private var panel: NSPanel?
    private var grantWatcher: AnyCancellable?
    private var dismissWork: DispatchWorkItem?
    private var placementTimer: Timer?
    private var lastPlacedFrame: NSRect?
    private let pollingDemandID = UUID()

    private init() {}

    func show(for kind: Kind) {
        dismiss()

        let language = L10n.shared.language
        let guide = FeatureStrings.permissionGuide(language)
        let permissionName = kind.permission.name(FeatureStrings.hub(language))
        let model = PermissionGuideModel()
        let view = PermissionGuideCard(guide: guide, permissionName: permissionName,
                                       kind: kind, language: language,
                                       model: model) { [weak self] in
            self?.dismiss()
        }

        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let frame = PermissionGuidePlacement.frame(size: size, settings: nil,
                                                   visible: visible, pointer: NSEvent.mouseLocation)

        // Non-activating, so System Settings keeps focus while the card
        // floats above it; joins every Space so the trip back finds it.
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        positionBesideSettings()
        // Only watch while visible. No AX permission is needed to read window
        // bounds, and there is no high-frequency window-following loop.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.positionBesideSettings()
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        placementTimer = timer
        Permissions.shared.setActivePermissionSurface(pollingDemandID,
                                                     visible: kind == .accessibility || kind == .screenRecording)

        let publisher: Published<Bool>.Publisher
        switch kind {
        case .accessibility: publisher = Permissions.shared.$accessibility
        case .screenRecording: publisher = Permissions.shared.$screenRecording
        case .fullDiskAccess: publisher = Permissions.shared.$fullDiskAccess
        case .appManagement: return // No public preflight; the guide must not claim success.
        }
        grantWatcher = publisher
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                model.granted = true
                self?.scheduleDismiss()
            }
    }

    private func positionBesideSettings() {
        guard let panel, NSEvent.pressedMouseButtons == 0 else { return }
        // Respect a position explicitly chosen by dragging the panel header.
        if let lastPlacedFrame, panel.frame != lastPlacedFrame {
            placementTimer?.invalidate()
            placementTimer = nil
            return
        }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences").first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]],
              let primaryScreen = NSScreen.screens.first else { return }
        let settingsFrame = windows.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 300, rect.height > 200 else { return nil }
            // WindowServer uses top-left coordinates; AppKit uses bottom-left.
            return CGRect(x: rect.minX, y: primaryScreen.frame.maxY - rect.maxY,
                          width: rect.width, height: rect.height)
        }.first
        guard let settingsFrame,
              let screen = NSScreen.screens.max(by: {
                  $0.frame.intersection(settingsFrame).area < $1.frame.intersection(settingsFrame).area
              }) else { return }
        let frame = PermissionGuidePlacement.frame(size: panel.frame.size, settings: settingsFrame,
                                                   visible: screen.visibleFrame, pointer: NSEvent.mouseLocation)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        lastPlacedFrame = frame
    }

    /// The success beat stays on screen for a moment, then the card leaves.
    private func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func dismiss() {
        placementTimer?.invalidate()
        placementTimer = nil
        lastPlacedFrame = nil
        dismissWork?.cancel()
        dismissWork = nil
        grantWatcher = nil
        panel?.orderOut(nil)
        panel = nil
        Permissions.shared.setActivePermissionSurface(pollingDemandID, visible: false)
    }
}

/// The card's only mutable state: flips once when the grant lands.
private final class PermissionGuideModel: ObservableObject {
    @Published var granted = false
}

private struct PermissionGuideCard: View {
    let guide: PermissionGuideStrings
    let permissionName: String
    let kind: PermissionGuideOverlay.Kind
    let language: AppLanguage
    @ObservedObject var model: PermissionGuideModel
    let onClose: () -> Void

    private var text: PermissionDragGuideStrings { PermissionDragGuideStrings(language: language) }
    private var appURL: URL { Bundle.main.bundleURL }
    private var isAppBundle: Bool { appURL.pathExtension.lowercased() == "app" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: model.granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.granted ? Color.green : Color.orange)
                Text(guide.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(permissionName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(guide.closeHelp)
            }

            VStack(alignment: .leading, spacing: 6) {
                stepRow(1, text.openStep + permissionName)
                stepRow(2, text.dragStep)
                stepRow(3, text.enableStep)
            }

            if isAppBundle {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appURL.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 15, weight: .semibold))
                        Text(text.dragLabel).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "hand.draw").foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .overlay(PermissionAppDragSource(url: appURL).accessibilityHidden(true))
                .help(text.dragLabel)
                Button(text.revealApp) {
                    NSWorkspace.shared.activateFileViewerSelecting([appURL])
                }
                .font(.caption)
            } else {
                Text(text.bundleRequired).font(.caption).foregroundStyle(.orange)
            }

            Text(text.repairNote)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                if model.granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(guide.granted)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    if kind == .accessibility || kind == .screenRecording {
                        ProgressView().controlSize(.small)
                    }
                    Text(kind == .appManagement ? PermissionPageStrings(language: language).checkInSettings
                         : kind == .fullDiskAccess ? text.restartNote : guide.waiting)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 390, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .animation(.easeOut(duration: 0.2), value: model.granted)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
