// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The Features hub. One switch per feature, grouped in plain language: off
/// means the feature disappears from the whole app (Settings, panel, menu
/// bar, shortcuts) and costs nothing; its configuration is kept for its
/// return. Permission management is available from its own Settings page.
struct FeatureHubSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var router = SettingsRouter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DefaultsKey.superKeySource) private var superKeySourceRaw =
        SuperKeySource.capsLock.rawValue
    /// Tracks the feature-target request currently being revealed, so a
    /// delayed retry from an older request cannot act after a newer one has
    /// already taken over (same convention as `SettingsSectionFocusModifier`).
    @State private var revealID = UUID()
    /// The row briefly tinted after a search or Command Bar selection lands
    /// on it, mirroring the section highlight `SettingsSectionFocusModifier`
    /// gives an ordinary page anchor.
    @State private var highlightedFeature: AppFeature?


    private var hub: FeatureHubStrings { FeatureStrings.hub(l10n.language) }

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onAppear { revealPendingFeatureTarget(using: proxy) }
                .onChange(of: router.requestID) { _, _ in revealPendingFeatureTarget(using: proxy) }
        }
    }

    private var content: some View {
        Form {
            Section {
                Button {
                    router.request(FeatureSettingsDestination(.permissions))
                } label: {
                    Label(PermissionPageStrings(language: l10n.language).title,
                          systemImage: "checkmark.shield")
                }
                Text(hub.intro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(String(format: hub.activeCountFormat,
                                    features.availableCount, features.installableCount))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Button(hub.installAllButton) {
                            FeatureRuntime.shared.setAllAvailable(true)
                        }
                        .disabled(features.availableCount == features.installableCount)
                        Button(hub.uninstallAllButton) {
                            FeatureRuntime.shared.setAllAvailable(false)
                        }
                        .disabled(features.availableCount == 0)
                    }
                    .controlSize(.small)
            }
            // The restart notice lives at the very top, never behind a
            // scroll: uninstalling anything makes it impossible to miss.
            if features.needsRestartToUnload {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.accentColor)
                        Text(hub.restartNote)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 10)
                        Button(hub.restartButton) {
                            FeatureRuntime.shared.relaunchApp()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.accentColor.opacity(0.12))
                }
            }
            featureSections
        }
        .formStyle(.grouped)
    }

    /// Consumes a pending Feature Hub target and scrolls the requested row into view. Retried once
    /// after the first run-loop turn, the same allowance
    /// `SettingsSectionFocusModifier` gives a freshly installed Form to
    /// register its row identities.
    private func revealPendingFeatureTarget(using proxy: ScrollViewProxy) {
        guard let request = router.pendingFeatureTarget else { return }
        router.consumeFeatureTarget(id: request.id)
        revealID = request.id
        DispatchQueue.main.async {
            guard self.revealID == request.id else { return }
            reveal(request.feature, using: proxy)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard self.revealID == request.id else { return }
                reveal(request.feature, using: proxy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard self.revealID == request.id else { return }
                    clearHighlight()
                }
            }
        }
    }

    private func reveal(_ feature: AppFeature, using proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(feature, anchor: .center)
            highlightedFeature = feature
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(feature, anchor: .center)
                highlightedFeature = feature
            }
        }
    }

    private func clearHighlight() {
        if reduceMotion {
            highlightedFeature = nil
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                highlightedFeature = nil
            }
        }
    }

    @ViewBuilder
    private var featureSections: some View {
        ForEach(FeatureGroup.allCases, id: \.self) { group in
            Section {
                ForEach(AppFeature.features(in: group), id: \.self) { feature in
                    FeatureHubRow(
                        feature: feature,
                        hub: hub,
                        symbolName: feature == .superKey
                            ? SuperKeySource.sanitized(superKeySourceRaw).systemImage
                            : feature.symbolName,
                        isHighlighted: highlightedFeature == feature
                    )
                        .id(feature)
                }
                if group == .monitor,
                   !FeatureVisibilitySupport.monitorFeatures.contains(where: \.isAvailable) {
                    Text(hub.monitorAllOffNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(groupTitle(group))
            }
        }
        Section {
            Text(hub.footerNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func groupTitle(_ group: FeatureGroup) -> String {
        switch group {
        case .windowsDock: return hub.groupWindowsDock
        case .mouseKeyboard: return hub.groupMouseKeyboard
        case .clipboardFiles: return hub.groupClipboardFiles
        case .sound: return hub.groupSound
        case .energyDisplay: return hub.groupEnergyDisplay
        case .appManagement: return FeatureStrings.settingsCategories(l10n.language).appManagement
        case .tools: return hub.groupTools
        case .monitor: return hub.groupMonitor
        }
    }
}

// MARK: - Feature row

private struct FeatureHubRow: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @State private var working = false
    let feature: AppFeature
    let hub: FeatureHubStrings
    let symbolName: String
    var isHighlighted: Bool = false

    private var installed: Bool { feature.isAvailable }

    /// Set only while this Mac cannot run the feature and it is not yet
    /// installed, so an install that predates the check keeps an ordinary
    /// row with its settings and Uninstall reachable.
    private var unsupportedReason: String? { feature.installBlockedReason }

    private var accessibilityTitle: String {
        let title = feature.hubTitle(l10n.s, hub: hub)
        return feature.isBeta ? "\(title). \(l10n.s.betaFeatureWarning)" : title
    }

    private var energyLabel: String {
        switch feature.energyProfile {
        case .idle: return hub.energyIdle
        case .mouse: return hub.energyMouse
        case .pointer: return hub.energyPointer
        case .keyboard: return hub.energyKeyboard
        case .inputs: return hub.energyInputs
        case .periodic: return hub.energyPeriodic
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if installed, feature.hasNavigableSettingsDestination {
                Button {
                    SettingsRouter.shared.request(feature.settingsDestination)
                } label: {
                    rowContent(showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(accessibilityTitle). \(feature.hubDescription(hub))")
                .accessibilityAddTraits(.isLink)
                .accessibilityRemoveTraits(.isButton)
            } else {
                rowContent(showsChevron: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(accessibilityTitle). \(feature.hubDescription(hub))")
                    .opacity(unsupportedReason == nil ? 1 : 0.4)
                    .saturation(unsupportedReason == nil ? 1 : 0)
            }
            if working {
                ProgressView()
                    .controlSize(.small)
            } else if installed {
                Button(hub.uninstallButton) { flip(to: false) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("\(hub.uninstallButton) \(accessibilityTitle)")
            } else if let reason = unsupportedReason {
                // .help() never fires on a disabled control, so the tooltip
                // has to sit on this wrapper. Flattening it loses the only
                // place the reason is shown.
                HStack(spacing: 0) {
                    Button(hub.installButton) { flip(to: true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(true)
                        .accessibilityLabel("\(hub.installButton) \(accessibilityTitle). \(reason)")
                }
                .help(reason)
            } else {
                Button(hub.installButton) { flip(to: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("\(hub.installButton) \(accessibilityTitle)")
            }
        }
        .padding(.vertical, 1)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.10 : 0))
                .allowsHitTesting(false)
        }
    }

    private func rowContent(showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(installed
                        ? AnyShapeStyle(Theme.spaceGradient)
                        : AnyShapeStyle(Color.secondary.opacity(0.22)))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(installed ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feature.hubTitle(l10n.s, hub: hub))
                        .foregroundStyle(installed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    if feature.isBeta {
                        Text(l10n.s.betaBadge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .accessibilityHidden(true)
                    }
                    ForEach(feature.permissions, id: \.self) { permission in
                        Image(systemName: permission.symbolName)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help(permission.name(hub))
                            .accessibilityHidden(true)
                    }
                    Text(energyLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .help(hub.energyHelp)
                        .accessibilityHidden(true)
                }
                Text(feature.hubDescription(hub))
                    .font(.caption)
                    .foregroundStyle(installed ? Color.secondary : Color.secondary.opacity(0.6))
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// A quick, honest beat of feedback: the spinner shows the action landed,
    /// then the row fades to its new state. The flip itself is instant.
    private func flip(to install: Bool) {
        guard !working else { return }
        working = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeOut(duration: 0.22)) {
                FeatureRuntime.shared.setAvailable(feature, install)
            }
            working = false
        }
    }
}

// MARK: - Permissions portal

struct PermissionsPortalSections: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var permissions = Permissions.shared
    let hub: FeatureHubStrings
    let visiblePermissions: [AppPermission]
    var compact = false
    var refreshID: UUID?
    @State private var pollingDemandID = UUID()

    init(hub: FeatureHubStrings,
         visiblePermissions: [AppPermission] = AppPermission.allCases,
         compact: Bool = false, refreshID: UUID? = nil) {
        self.hub = hub
        self.visiblePermissions = visiblePermissions
        self.compact = compact
        self.refreshID = refreshID
    }

    var body: some View {
        ForEach(visiblePermissions, id: \.self) { permission in
            PermissionPortalRow(permission: permission,
                                hub: hub,
                                status: status(for: permission), compact: compact)
        }
        .onAppear {
            // Statuses that only refresh at launch/activation get a fresh
            // read the moment the portal shows; automation is checked off the
            // main thread because the AE round trip can block briefly.
            permissions.refresh()
            if visiblePermissions.contains(.accessibility)
                || visiblePermissions.contains(.screenRecording) {
                permissions.setActivePermissionSurface(pollingDemandID, visible: true)
            }
            refreshAutomation()
        }
        .onDisappear {
            permissions.setActivePermissionSurface(pollingDemandID, visible: false)
        }
        .onChange(of: refreshID) { _, _ in refreshAutomation() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAutomation()
        }
    }

    private func refreshAutomation() {
        permissions.refreshAutomation()
    }

    private func status(for permission: AppPermission) -> PermissionPortalRow.Status {
        switch permission {
        case .accessibility: return permissions.accessibility ? .granted : .missing
        case .screenRecording: return permissions.screenRecording ? .granted : .missing
        case .fullDiskAccess: return permissions.fullDiskAccess ? .granted : .missing
        case .filesAndFolders:
            switch permissions.downloadsAccess {
            case .granted: return .granted
            case .denied: return .missing
            case .unknown, .undetermined: return .unknown
            }
        case .notifications:
            switch permissions.notifications {
            case .granted: return .granted
            case .denied: return .missing
            case .undetermined: return .undetermined
            case .unknown: return .unknown
            }
        case .automationFinder: return automationStatus(.finder)
        case .automationTerminal: return automationStatus(.terminal)
        case .audioCapture:
            // Tap creation can fail for device/routing reasons too; never
            // present a generic engine failure as a confirmed TCC denial.
            return .unknown
        case .microphone:
            switch permissions.microphone {
            case .granted: return .granted
            case .denied: return .missing
            case .undetermined: return .undetermined
            case .unknown: return .unknown
            }
        case .camera:
            switch permissions.camera {
            case .granted: return .granted
            case .denied: return .missing
            case .undetermined: return .undetermined
            case .unknown: return .unknown
            }
        case .appManagement:
            // macOS has no public preflight API for this permission. The
            // system records the app only after its first protected write.
            return .unknown
        }
    }

    private func automationStatus(_ target: Permissions.AutomationTarget) -> PermissionPortalRow.Status {
        switch permissions.automation[target] {
        case .granted: return .granted
        case .denied: return .missing
        case .undetermined: return .undetermined
        case .notDeterminable, .none: return .unknown
        }
    }
}

private struct PermissionPortalRow: View {
    enum Status { case granted, missing, undetermined, unknown }

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    let permission: AppPermission
    let hub: FeatureHubStrings
    let status: Status
    var compact = false

    @ViewBuilder
    var body: some View {
        if compact {
            HStack(spacing: 12) {
                Image(systemName: permission.symbolName)
                    .font(.system(size: 21))
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(permission.name(hub)).fontWeight(.medium)
                    Text(permission.explainer(hub))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(usedByLine)
                }
                Spacer(minLength: 8)
                statusChip
                Button(actionTitle) {
                    if status != .granted && hasRequestFlow { request() }
                    else { openSystemSettings() }
                }
                .frame(minWidth: 64)
                .disabled((permission == .automationFinder || permission == .automationTerminal)
                          && permissions.requestingAutomation)
                .help(hub.openSystemSettings)
            }
            .padding(.vertical, 8)
        } else {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(permission.name(hub))
                        .fontWeight(.medium)
                    statusChip
                }
                Text(permission.explainer(hub))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(usedByLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if status == .granted, activeFeatures.isEmpty {
                    unusedCard
                }
                HStack(spacing: 8) {
                    if status != .granted, hasRequestFlow {
                        Button(hub.requestButton) { request() }
                    }
                    Button(hub.openSystemSettings) { openSystemSettings() }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        }
    }

    private var activeFeatures: [AppFeature] {
        AppFeature.activeFeatures(using: permission).filter {
            permission != .notifications || $0 != .monitorPower || PowerSampler.hasInternalBattery
        }
    }

    private var usedByLine: String {
        let names = activeFeatures.map { $0.hubTitle(l10n.s, hub: hub) }
        guard !names.isEmpty else { return hub.usedByNone }
        return String(format: hub.usedByFormat, names.joined(separator: ", "))
    }

    private var statusChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(chipColor)
                .frame(width: 6, height: 6)
            Text(chipText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chipColor: Color {
        switch status {
        case .granted: return .green
        case .missing: return .orange
        case .unknown, .undetermined: return .secondary
        }
    }

    private var chipText: String {
        let text = PermissionPageStrings(language: l10n.language)
        if permission == .filesAndFolders {
            switch status {
            case .granted: return text.downloadsAccessible
            case .missing: return text.downloadsDenied
            default: return text.notChecked
            }
        }
        if status == .unknown {
            switch permission {
            case .automationFinder, .automationTerminal: return text.targetNotChecked
            case .audioCapture: return text.checkWhileUsing
            case .appManagement: return text.checkInSettings
            default: break
            }
        }
        switch status {
        case .granted: return hub.statusGranted
        case .missing: return hub.statusMissing
        case .unknown: return hub.statusUnknown
        case .undetermined: return PermissionPageStrings(language: l10n.language).notRequested
        }
    }

    private var unusedCard: some View {
        Text(hub.unusedBanner)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
    }

    private var hasRequestFlow: Bool {
        switch permission {
        case .accessibility, .screenRecording, .fullDiskAccess: return true
        case .notifications: return Permissions.shared.notifications == .undetermined
        case .camera: return Permissions.shared.camera == .undetermined
        case .microphone: return Permissions.shared.microphone == .undetermined
        case .filesAndFolders: return true
        case .automationFinder, .automationTerminal: return status != .missing
        case .audioCapture, .appManagement: return false
        }
    }

    private func request() {
        switch permission {
        case .accessibility: Permissions.shared.requestAccessibility()
        case .screenRecording: Permissions.shared.requestScreenRecording()
        case .fullDiskAccess: Permissions.shared.requestFullDiskAccess()
        case .notifications:
            Notifier.requestPermission()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Permissions.shared.refresh()
            }
        case .camera: Permissions.shared.requestCamera()
        case .microphone: Permissions.shared.requestMicrophone()
        case .filesAndFolders:
            if status == .missing { permissions.openFilesAndFoldersSettings() }
            else { permissions.checkDownloadsAccess() }
        case .automationFinder: permissions.requestAutomation(.finder)
        case .automationTerminal: permissions.requestAutomation(.terminal)
        case .audioCapture, .appManagement:
            break
        }
    }

    private var actionTitle: String {
        let text = PermissionPageStrings(language: l10n.language)
        switch permission {
        case .filesAndFolders: return status == .missing ? hub.openSystemSettings : text.checkDownloads
        case .audioCapture: return text.authorizationHelp
        case .appManagement: return hub.openSystemSettings
        default: return status != .granted && hasRequestFlow ? hub.requestButton : text.manage
        }
    }

    private func openSystemSettings() {
        switch permission {
        case .accessibility: Permissions.shared.openAccessibilitySettings()
        case .screenRecording: Permissions.shared.openScreenRecordingSettings()
        case .fullDiskAccess: Permissions.shared.openFullDiskAccessSettings()
        case .filesAndFolders: permissions.checkDownloadsAccess()
        case .notifications: Permissions.shared.openNotificationSettings()
        case .automationFinder, .automationTerminal: Permissions.shared.openAutomationSettings()
        case .audioCapture:
            let text = PermissionPageStrings(language: l10n.language)
            let alert = NSAlert()
            alert.messageText = text.authorizationHelp
            alert.informativeText = text.audioInstructions
            alert.addButton(withTitle: hub.openSystemSettings)
            alert.addButton(withTitle: l10n.s.uninstallerCancel)
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.shared.openAudioCaptureSettings()
            }
        case .microphone: Permissions.shared.openMicrophoneSettings()
        case .camera: Permissions.shared.openCameraSettings()
        case .appManagement: Permissions.shared.openAppManagementSettings()
        }
    }
}

// MARK: - Titles, descriptions and permission names

extension AppFeature {
    /// Titles reuse the strings users already see across the app; only names
    /// with no clean existing form live in the hub strings.
    func hubTitle(_ s: Strings, hub: FeatureHubStrings) -> String {
        switch self {
        case .dynamicIsland: return "灵动岛"
        case .switcher: return s.switcherSection
        case .dockPreview: return s.dockPreviewName
        case .dockClick: return hub.titleDockClick
        case .windowMaximizer: return s.windowMaximizeName
        case .windowLayout: return FeatureStrings.windowLayout(L10n.shared.language).title
        case .autoQuit: return s.autoQuitName
        case .scrollInverter: return s.invertMouseScroll
        case .focusFollowsMouse: return s.focusFollowsMouseName
        case .smoothScroll: return s.smoothScrollName
        case .mouseNavigation: return hub.titleMouseNavigation
        case .mouseButtonShortcuts: return FeatureStrings.mouseButtons(L10n.shared.language).pageTitle
        case .middleClick: return s.middleClickSection
        case .keyboardDebounce: return s.keyDebounceName
        case .textSnippets: return FeatureStrings.snippets(L10n.shared.language).pageTitle
        case .superKey: return FeatureStrings.superKey(L10n.shared.language).pageTitle
        case .inputSourceAutomation:
            return InputSourceAutomationStrings.current(L10n.shared.language).pageTitle
        case .clipboardHistory: return FeatureStrings.clipboard(L10n.shared.language).title
        case .pastePlain: return s.pastePlainName
        case .finderCutPaste: return s.cutPasteName
        case .finderRename: return FeatureStrings.finderRename(L10n.shared.language).hubTitle
        case .shelf: return s.shelfName
        case .urlCleaner: return s.urlCleanerName
        case .diskImageInstaller:
            return FeatureStrings.diskImageInstaller(L10n.shared.language).title
        case .mixer: return s.mixerSection
        case .soundOutputSwitcher: return s.soundOutputSwitcherTitle
        case .micMute: return s.micMuteName
        case .musicBlock: return hub.titleMusicBlock
        case .keepAwake: return s.keepAwakeTitle
        case .brightness: return FeatureStrings.brightness(L10n.shared.language).pageTitle
        case .extraBrightness: return s.extraBrightnessName
        case .bluetoothSleep: return FeatureStrings.bluetoothSleep(L10n.shared.language).pageTitle
        case .awayLock: return AwayLockStrings.current.title
        case .batteryManagement: return "电池管理"
        case .quickLauncher: return s.launcherName
        case .quickToggles: return FeatureStrings.quickToggles(L10n.shared.language).pageTitle
        case .colorPicker: return s.colorPickerName
        case .screenOCR: return s.ocrName
        case .screenshot: return FeatureStrings.screenshot(L10n.shared.language).pageTitle
        case .screenRecorder: return FeatureStrings.recorder(L10n.shared.language).pageTitle
        case .cameraPreview: return FeatureStrings.cameraPreview(L10n.shared.language).pageTitle
        case .radialMenu: return FeatureStrings.radialMenu(L10n.shared.language).pageTitle
        case .scratchpad: return FeatureStrings.scratchpad(L10n.shared.language).pageTitle
        case .networkInfo: return NetworkInfoStrings(language: L10n.shared.language).title
        case .translation: return TranslationStrings.current[.title]
        case .commandBar: return FeatureStrings.commandBar(L10n.shared.language).pageTitle
        case .cleaningMode: return s.cleaningMenuItem
        case .mediaTools: return s.mediaName
        case .cleaner: return s.cleanerName
        case .uninstaller: return s.uninstallerName
        case .killProcess: return FeatureStrings.killProcess(L10n.shared.language).pageTitle
        case .homebrew: return s.homebrewName
        case .appUpdates: return FeatureStrings.appUpdates(L10n.shared.language).pageTitle
        case .menuBarIcons: return MenuBarIconCollapserStrings.current.title
        case .monitorCPU: return s.monitorShowCPU
        case .monitorGPU: return s.monitorShowGPU
        case .monitorMemory: return s.monitorShowMemory
        case .monitorNetwork: return s.monitorShowNetwork
        case .monitorDisk: return s.diskSection
        case .monitorPower: return s.powerSection
        case .fanControl: return FeatureStrings.fanControl(L10n.shared.language).title
        }
    }

    func hubDescription(_ hub: FeatureHubStrings) -> String {
        switch self {
        case .dynamicIsland: return "在刘海区域显示系统音乐与视频播放控制"
        case .switcher: return hub.descSwitcher
        case .dockPreview: return hub.descDockPreview
        case .dockClick: return hub.descDockClick
        case .windowMaximizer: return hub.descWindowMaximizer
        case .windowLayout: return hub.descWindowLayout
        case .autoQuit: return hub.descAutoQuit
        case .scrollInverter: return hub.descScrollInverter
        case .focusFollowsMouse: return L10n.shared.s.focusFollowsMouseCaption
        case .smoothScroll: return hub.descSmoothScroll
        case .mouseNavigation: return hub.descMouseNavigation
        case .mouseButtonShortcuts: return FeatureStrings.mouseButtons(L10n.shared.language).hubDescription
        case .middleClick: return hub.descMiddleClick
        case .keyboardDebounce: return hub.descKeyboardDebounce
        case .textSnippets: return FeatureStrings.snippets(L10n.shared.language).hubDescription
        case .superKey: return FeatureStrings.superKey(L10n.shared.language).hubDescription
        case .inputSourceAutomation:
            return InputSourceAutomationStrings.current(L10n.shared.language).description
        case .clipboardHistory: return hub.descClipboardHistory
        case .pastePlain: return hub.descPastePlain
        case .finderCutPaste: return hub.descFinderCutPaste
        case .finderRename: return FeatureStrings.finderRename(L10n.shared.language).hubDescription
        case .shelf: return hub.descShelf
        case .urlCleaner: return hub.descURLCleaner
        case .diskImageInstaller:
            return FeatureStrings.diskImageInstaller(L10n.shared.language).hubDescription
        case .mixer: return hub.descMixer
        case .soundOutputSwitcher: return hub.descSoundOutputSwitcher
        case .micMute: return hub.descMicMute
        case .musicBlock: return hub.descMusicBlock
        case .keepAwake: return hub.descKeepAwake
        case .brightness: return FeatureStrings.brightness(L10n.shared.language).hubDescription
        case .extraBrightness: return hub.descExtraBrightness
        case .bluetoothSleep: return FeatureStrings.bluetoothSleep(L10n.shared.language).hubDescription
        case .awayLock: return AwayLockStrings.current.caption
        case .batteryManagement: return "设置充电上限并在菜单栏查看电池状态。"
        case .quickLauncher: return hub.descQuickLauncher
        case .quickToggles: return FeatureStrings.quickToggles(L10n.shared.language).hubDescription
        case .colorPicker: return hub.descColorPicker
        case .screenOCR: return hub.descScreenOCR
        case .screenshot: return FeatureStrings.screenshot(L10n.shared.language).hubDescription
        case .screenRecorder: return FeatureStrings.recorder(L10n.shared.language).hubDescription
        case .cameraPreview: return FeatureStrings.cameraPreview(L10n.shared.language).hubDescription
        case .radialMenu: return FeatureStrings.radialMenu(L10n.shared.language).hubDescription
        case .scratchpad: return FeatureStrings.scratchpad(L10n.shared.language).hubDescription
        case .networkInfo: return NetworkInfoStrings(language: L10n.shared.language).summary
        case .translation: return TranslationStrings.current[.caption]
        case .commandBar: return FeatureStrings.commandBar(L10n.shared.language).hubDescription
        case .cleaningMode: return hub.descCleaningMode
        case .mediaTools: return hub.descMediaTools
        case .cleaner:
            let description = hub.descCleaner
            guard WhatsAppDownloadSupport.isEnabled else {
                return description
            }
            return description + " · "
                + FeatureStrings.whatsAppDownloads(L10n.shared.language).hubDescription
        case .uninstaller: return hub.descUninstaller
        case .killProcess: return FeatureStrings.killProcess(L10n.shared.language).hubDescription
        case .homebrew: return hub.descHomebrew
        case .appUpdates: return FeatureStrings.appUpdates(L10n.shared.language).hubDescription
        case .menuBarIcons: return MenuBarIconCollapserStrings.current.caption
        case .monitorCPU: return hub.descMonitorCPU
        case .monitorGPU: return hub.descMonitorGPU
        case .monitorMemory: return hub.descMonitorMemory
        case .monitorNetwork: return hub.descMonitorNetwork
        case .monitorDisk: return hub.descMonitorDisk
        case .monitorPower: return hub.descMonitorPower
        case .fanControl: return FeatureStrings.fanControl(L10n.shared.language).hubDescription
        }
    }
}

extension AppPermission {
    func name(_ hub: FeatureHubStrings) -> String {
        switch self {
        case .accessibility: return hub.permAccessibility
        case .screenRecording: return hub.permScreenRecording
        case .fullDiskAccess: return hub.permFullDisk
        case .filesAndFolders: return hub.permFilesAndFolders
        case .notifications: return hub.permNotifications
        case .automationFinder: return hub.permAutomationFinder
        case .automationTerminal: return hub.permAutomationTerminal
        case .audioCapture: return hub.permAudioCapture
        case .microphone: return FeatureStrings.recorder(L10n.shared.language).microphonePermissionName
        case .camera: return FeatureStrings.cameraPreview(L10n.shared.language).permName
        case .appManagement: return FeatureStrings.settingsCategories(L10n.shared.language).appManagement
        }
    }

    func explainer(_ hub: FeatureHubStrings) -> String {
        switch self {
        case .accessibility: return hub.explainAccessibility
        case .screenRecording: return hub.explainScreenRecording
        case .fullDiskAccess: return hub.explainFullDisk
        case .filesAndFolders: return hub.explainFilesAndFolders
        case .notifications: return hub.explainNotifications
        case .automationFinder: return hub.explainAutomationFinder
        case .automationTerminal: return hub.explainAutomationTerminal
        case .audioCapture: return hub.explainAudioCapture
        case .microphone:
            return FeatureStrings.recorder(L10n.shared.language).microphonePermissionExplain
        case .camera: return FeatureStrings.cameraPreview(L10n.shared.language).permExplain
        case .appManagement: return hub.explainAppManagement
        }
    }
}
