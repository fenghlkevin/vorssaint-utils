// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct PanelWindowLayoutView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = WindowLayoutService.shared
    @AppStorage(DefaultsKey.windowLayoutShortcutsEnabled) private var shortcutsEnabled = true
    @AppStorage(DefaultsKey.windowEdgeSnapEnabled) private var edgeSnapEnabled = false
    @AppStorage(DefaultsKey.windowGestureEnabled) private var gestureEnabled = false
    @AppStorage(DefaultsKey.windowGestureModifiers) private var gestureModifiers = WindowGestureSupport.defaultModifierStorageValue
    @AppStorage(DefaultsKey.windowLayoutHiddenActions) private var hiddenActionsRaw = ""
    @State private var editingActions = false
    @State private var showMore = false

    var onClose: () -> Void

    private var text: WindowLayoutFeatureStrings {
        FeatureStrings.windowLayout(l10n.language)
    }

    private var copy: WindowSnapCopy { WindowSnapCopy(language: l10n.language) }

    private let columns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            intro
            actionGroup(title: text.halves, actions: [.leftHalf, .rightHalf, .topHalf, .bottomHalf])
            actionGroup(title: text.thirds, actions: [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds])
            actionGroup(title: text.corners, actions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
            actionGroup(title: text.other, actions: [.maximize, .center, .restore, .nextDisplay])
            DisclosureGroup(copy.advanced, isExpanded: $showMore) {
                actionGroup(title: text.sixths, actions: [
                    .topLeftSixth, .topCenterSixth, .topRightSixth,
                    .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
                ])
                actionGroup(title: text.other, actions: [.marginMaximize, .fullScreen, .previousDisplay])
                advancedControls
            }
            .font(.system(size: 11))
            if let message = resultMessage {
                Label(message, systemImage: resultSymbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(resultColor)
                    .panelCard()
            }
        }
        .onAppear {
            PanelInteractionState.shared.viewKeepsPopoverOpen = true
            refreshSnapState()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSnapState()
        }
        .onDisappear { PanelInteractionState.shared.viewKeepsPopoverOpen = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(text.title, systemImage: "rectangle.3.group")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            // Same tune affordance as the quick panel: most people use a
            // handful of layouts, so actions can be hidden from the grid.
            // Hiding never touches an assigned shortcut.
            Button {
                withAnimation(.easeOut(duration: 0.15)) { editingActions.toggle() }
            } label: {
                Image(systemName: editingActions ? "checkmark.circle.fill" : "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(editingActions ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(l10n.s.menuSettings)
            .accessibilityLabel(l10n.s.menuSettings)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(l10n.s.uninstallerCancel)
            .accessibilityLabel(l10n.s.menuClose)
        }
    }

    private var hiddenActions: Set<WindowLayoutAction> {
        WindowLayoutAction.hiddenActions(from: hiddenActionsRaw)
    }

    private func toggleHidden(_ action: WindowLayoutAction) {
        var hidden = hiddenActions
        if !hidden.insert(action).inserted { hidden.remove(action) }
        hiddenActionsRaw = WindowLayoutAction.hiddenActionsStorageValue(hidden)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(copy.activation, isOn: $edgeSnapEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11, weight: .semibold))
                .onChange(of: edgeSnapEnabled) { _, _ in service.syncWithPreferences() }
            Label(!permissions.accessibility ? text.missingPermission
                  : (edgeSnapEnabled ? copy.enabled : copy.disabled),
                  systemImage: edgeSnapEnabled ? "checkmark.circle.fill" : "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            WindowSnapGuide(compact: true)
            Divider()
            Text(text.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(text.shortcuts, isOn: $shortcutsEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 10.5, weight: .medium))
                .onChange(of: shortcutsEnabled) { _, _ in
                    WindowLayoutService.shared.syncWithPreferences()
                }
            if shortcutsEnabled {
                Text(text.shortcutsCaption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !permissions.accessibility {
                Button {
                    Permissions.shared.requestAccessibility()
                    Permissions.shared.openAccessibilitySettings()
                } label: {
                    Label(text.missingPermission, systemImage: "hand.raised.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .panelCard()
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Toggle(text.gestureEnable, isOn: $gestureEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 10.5, weight: .medium))
                .onChange(of: gestureEnabled) { _, _ in
                    WindowLayoutService.shared.syncWithPreferences()
                }
            if gestureEnabled {
                WindowGestureModifierPicker(storageValue: $gestureModifiers,
                                            title: text.gestureModifiers,
                                            compact: true)
                    .onChange(of: gestureModifiers) { _, _ in
                        WindowLayoutService.shared.syncWithPreferences()
                    }
                WindowGestureHints(modifierStorage: gestureModifiers,
                                   moveText: text.gestureMove,
                                   resizeText: text.gestureResize,
                                   compact: true)
                Text(text.gestureResizeHint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refreshSnapState() {
        WindowLayoutService.shared.syncWithPreferences()
    }

    @ViewBuilder
    private func actionGroup(title groupTitle: String, actions: [WindowLayoutAction]) -> some View {
        let hidden = hiddenActions
        let shown = editingActions ? actions : actions.filter { !hidden.contains($0) }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(groupTitle.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                    ForEach(shown) { action in
                        Button {
                            if editingActions {
                                withAnimation(.easeOut(duration: 0.15)) { toggleHidden(action) }
                            } else {
                                service.apply(action)
                            }
                        } label: {
                            VStack(spacing: 2) {
                                HStack(spacing: 6) {
                                    WindowLayoutGlyph(action: action)
                                    if editingActions {
                                        Image(systemName: hidden.contains(action) ? "eye.slash" : "eye")
                                    }
                                    Text(title(for: action))
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)
                                }
                                if shortcutsEnabled, action.supportsShortcut,
                                   let shortcut = action.savedShortcut {
                                    Text(shortcut.displayString)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .opacity(editingActions && hidden.contains(action) ? 0.45 : 1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!permissions.accessibility && !editingActions)
                    }
                }
            }
            .panelCard()
        }
    }

    private func title(for action: WindowLayoutAction) -> String {
        action.title(text)
    }

    private var resultMessage: String? {
        switch service.lastResult {
        case .success(let restored): return restored ? text.restored : text.done
        case .failure(.missingAccessibility): return text.missingPermission
        case .failure(.noWindow): return text.noWindow
        case .failure(.noRestore): return text.noRestore
        case .failure(.failed): return text.failed
        case nil: return nil
        }
    }

    private var resultColor: Color {
        switch service.lastResult {
        case .success: return .green
        case .failure: return .orange
        case nil: return .secondary
        }
    }

    private var resultSymbol: String {
        switch service.lastResult {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case nil: return "info.circle"
        }
    }
}
