// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Configuration for the independent ring switcher.
struct RadialSwitcherSettings: View {
    @ObservedObject private var service = RadialSwitcherService.shared
    @ObservedObject private var trackpad = RadialTrackpadService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.radialSwitcherPresentation) private var presentation = "ring"
    @AppStorage(DefaultsKey.radialSwitcherEnabled) private var enabled = false
    @AppStorage(DefaultsKey.radialSwitcherShortcut) private var shortcut =
        GlobalShortcut.radialSwitcherDefault.storageValue
    @AppStorage(DefaultsKey.radialSwitcherActionShortcut) private var actionShortcut = ""
    @AppStorage(DefaultsKey.radialSwitcherPreviews) private var previews = true
    @AppStorage(DefaultsKey.radialSwitcherSortByName) private var sortByName = true
    @AppStorage(DefaultsKey.radialSwitcherIncludeMinimized) private var includeMinimized = true
    @AppStorage(DefaultsKey.radialSwitcherAppPageSize) private var appPageSize = 12
    @AppStorage(DefaultsKey.radialSwitcherWindowPageSize) private var windowPageSize = 6
    @AppStorage(DefaultsKey.radialSwitcherHoldToSelect) private var holdToSelect = false
    @AppStorage(DefaultsKey.radialSwitcherTrackpadTap) private var trackpadTap = 0
    @AppStorage(DefaultsKey.radialSwitcherPinchMinimize) private var pinchMinimize = false
    @State private var favorites = RadialSwitcherStorage.favorites()
    @State private var actionProfiles = RadialSwitcherStorage.actions()
    @State private var appRules = RadialSwitcherStorage.appRules()
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        Form {
            Section("环形切换器") {
                Toggle("启用环形切换器", isOn: $enabled)
                Picker("展示形式", selection: $presentation) {
                    Text("环形").tag("ring")
                    Text("双栏").tag("columns")
                }
                Text("双栏：左侧选择应用，右侧显示窗口或标签；松开 Command 激活当前选择。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("独立切换应用、窗口和 Safari / Chrome / Edge 标签页，不改变原应用切换器。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("全局快捷键")
                    Spacer()
                    ShortcutRecorderButton(
                        shortcut: GlobalShortcut(storageValue: shortcut) ?? .radialSwitcherDefault,
                        isEnabled: enabled,
                        waitingTitle: l10n.s.shortcutPressKeys,
                        invalidAction: {},
                        captureAction: { shortcut = $0.storageValue; service.syncWithPreferences() }
                    ).frame(width: 130)
                }
                if service.registrationFailed {
                    Text("请授予辅助功能权限以接管系统快捷键。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("使用 ⌘Tab") {
                    shortcut = GlobalShortcut.switcherDefault.storageValue
                    holdToSelect = true
                    service.syncWithPreferences()
                }.disabled(!enabled)
                Text("启用后可接管系统 ⌘Tab；与 App 切换快捷键相同时，环形切换器优先。按 Tab 前进、Shift+Tab 后退，松开 Command 确认。点击一级图标直接切换；点中心“展开窗口”或按 ` 展开；浏览器窗口和标签在同一层切换。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("按住修饰键选择，松开确认", isOn: $holdToSelect)
                    .disabled(shortcut == GlobalShortcut.switcherDefault.storageValue)
                HStack {
                    Text("应用快捷操作快捷键")
                    Spacer()
                    ShortcutRecorderButton(
                        shortcut: GlobalShortcut(storageValue: actionShortcut) ?? .radialSwitcherDefault,
                        isEnabled: enabled,
                        waitingTitle: l10n.s.shortcutPressKeys,
                        emptyTitle: actionShortcut.isEmpty ? "未设置" : nil,
                        clearAction: { actionShortcut = ""; service.syncWithPreferences() },
                        invalidAction: {},
                        captureAction: { actionShortcut = $0.storageValue; service.syncWithPreferences() }
                    ).frame(width: 130)
                }
                Button("试用环形切换器") { service.present() }.disabled(!enabled)
            }

            Section("列表与预览") {
                Picker("应用排序", selection: $sortByName) {
                    Text("最近使用").tag(false)
                    Text("应用名称").tag(true)
                }
                Text("最近使用：从 A 切换到 B 后，再按一次 ⌘Tab 优先返回 A。环形与双栏均适用；每次呼出时更新顺序，选择过程中保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("包含已最小化窗口", isOn: $includeMinimized)
                Toggle("悬停显示窗口预览", isOn: $previews)
                Stepper("每页应用：\(appPageSize)", value: $appPageSize, in: 4...24)
                Stepper("每页窗口或标签：\(windowPageSize)", value: $windowPageSize, in: 2...8)
            }

            Section("触控板") {
                Picker("轻点呼出", selection: $trackpadTap) {
                    Text("关闭").tag(0)
                    Text("三指轻点").tag(3)
                    Text("四指轻点").tag(4)
                }
                Toggle("三指捏合最小化当前窗口", isOn: $pinchMinimize)
                Text(trackpad.status).font(.caption).foregroundStyle(.secondary)
                Button("重试连接触控板") { trackpad.sync(force: true) }
            }

            Section("常用应用") {
                Text("按住 Option 显示常用应用；双击环中心可固定或关闭。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(favorites) { favorite in
                    HStack {
                        Text(favorite.name)
                        Spacer()
                        Button("移除") { favorites.removeAll { $0.id == favorite.id } }
                    }
                }
                Button("添加应用…") { chooseApplication(for: .favorite) }
            }

            Section("应用管理") {
                Text("按应用选择窗口或标签页，也可以从环中隐藏应用。标签页支持 Safari、Chrome 和 Edge。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(runningApps, id: \.processIdentifier) { app in
                    if let id = app.bundleIdentifier {
                        Picker(app.localizedName ?? id, selection: Binding(
                            get: { appRules[id] ?? "windows" },
                            set: { appRules[id] = $0 }
                        )) {
                            Text("窗口").tag("windows")
                            if RadialBrowserEvents.supports(id) {
                                Text("标签页").tag("tabs")
                            }
                            Text("隐藏").tag("hidden")
                        }
                    }
                }
                Button("刷新应用列表") { refreshApps() }
            }

            Section("应用内快捷操作") {
                Text("为应用配置操作名称与快捷键。用独立快捷键打开当前应用的操作环。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($actionProfiles) { $profile in
                    DisclosureGroup(profile.appName) {
                        ForEach($profile.actions) { $action in
                            HStack {
                                TextField("操作名称", text: $action.name)
                                    .frame(minWidth: 120)
                                ShortcutRecorderButton(
                                    shortcut: GlobalShortcut(storageValue: action.shortcut)
                                        ?? .radialSwitcherDefault,
                                    isEnabled: true,
                                    waitingTitle: l10n.s.shortcutPressKeys,
                                    emptyTitle: action.shortcut.isEmpty ? "录制" : nil,
                                    clearAction: { action.shortcut = "" },
                                    invalidAction: {},
                                    captureAction: { action.shortcut = $0.storageValue }
                                ).frame(width: 120)
                                Button(role: .destructive) {
                                    profile.actions.removeAll { $0.id == action.id }
                                } label: { Image(systemName: "trash") }
                            }
                        }
                        Button("添加操作") {
                            profile.actions.append(RadialAppAction(name: "", shortcut: ""))
                        }
                        .disabled(profile.actions.count >= 48)
                        Button("移除应用", role: .destructive) {
                            actionProfiles.removeAll { $0.id == profile.id }
                        }
                    }
                }
                Button("添加应用…") { chooseApplication(for: .actions) }
                    .disabled(actionProfiles.count >= 64)
            }
        }
        .formStyle(.grouped)
        .onChange(of: presentation) { _, _ in service.dismiss() }
        .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
        .onChange(of: holdToSelect) { _, _ in service.syncWithPreferences() }
        .onChange(of: shortcut) { _, _ in service.syncWithPreferences() }
        .onChange(of: trackpadTap) { _, _ in trackpad.sync() }
        .onChange(of: pinchMinimize) { _, _ in trackpad.sync() }
        .onChange(of: favorites) { _, value in
            UserDefaults.standard.set(try? JSONEncoder().encode(value),
                                      forKey: DefaultsKey.radialSwitcherFavorites)
        }
        .onChange(of: actionProfiles) { _, value in
            UserDefaults.standard.set(try? JSONEncoder().encode(value),
                                      forKey: DefaultsKey.radialSwitcherActionProfiles)
        }
        .onChange(of: appRules) { _, value in
            UserDefaults.standard.set(value, forKey: DefaultsKey.radialSwitcherAppRules)
        }
        .onAppear { refreshApps() }
    }

    private enum AddTarget { case favorite, actions }

    private func chooseApplication(for target: AddTarget) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { result in
            guard result == .OK else { return }
            for url in panel.urls {
                guard let app = RadialFavorite.read(url) else { continue }
                switch target {
                case .favorite:
                    if !favorites.contains(where: { $0.id == app.id }) { favorites.append(app) }
                case .actions:
                    if !actionProfiles.contains(where: { $0.id == app.id }) {
                        actionProfiles.append(RadialActionProfile(bundleID: app.bundleID,
                                                                  appName: app.name, actions: []))
                    }
                }
            }
        }
    }

    private func refreshApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }
}
