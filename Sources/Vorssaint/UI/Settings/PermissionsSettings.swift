// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct PermissionPageStrings {
    let language: AppLanguage
    private var chinese: Bool { [.zhHans, .zhTW, .zhHK].contains(language) }
    var title: String { chinese ? "权限管理" : "Permissions" }
    var manage: String { chinese ? "管理" : "Manage" }
    var refresh: String { chinese ? "刷新" : "Refresh" }
    var notRequested: String { chinese ? "尚未请求" : "Not requested" }
    var notChecked: String { chinese ? "尚未检查下载文件夹" : "Downloads not checked" }
    var downloadsAccessible: String { chinese ? "下载文件夹可访问" : "Downloads accessible" }
    var downloadsDenied: String { chinese ? "下载文件夹访问被拒绝" : "Downloads access denied" }
    var checkDownloads: String { chinese ? "检查访问" : "Check access" }
    var targetNotChecked: String { chinese ? "需启动目标 App 后检查" : "Launch target to check" }
    var checkWhileUsing: String { chinese ? "使用混音器时确认" : "Confirmed when using mixer" }
    var checkInSettings: String { chinese ? "需在系统设置中确认" : "Check in System Settings" }
    var authorizationHelp: String { chinese ? "授权说明" : "How to authorize" }
    var audioInstructions: String {
        chinese ? "请先让一个 App 播放声音，再在 Vorssaint 菜单面板的混音器中调整该 App 的音量。系统会在需要时请求音频访问。若曾拒绝，请在系统设置中开启系统音频录制权限。系统不提供此权限的独立查询接口，混音器启动失败也可能是音频设备问题。"
            : "Play audio in an app, then adjust that app’s volume in the Vorssaint menu panel mixer. macOS requests audio access when needed. If previously denied, enable system audio recording in System Settings. There is no standalone permission query; mixer startup failures can also be device errors."
    }
    var intro: String {
        chinese ? "查看权限用途，并前往系统设置管理授权。"
            : "Review permission usage and manage access in System Settings."
    }
    var note: String {
        chinese ? "授权需由你在 macOS 中确认，返回后会自动刷新状态。部分权限只能在系统设置中查看。"
            : "Confirm access in macOS. Status refreshes when you return. Some permissions can only be checked in System Settings."
    }
    var resetNote: String {
        chinese ? "重置此 App 的系统隐私权限，保留数据、功能配置、登录项和硬件控制后台。相关功能需重新授权；通知权限请在系统设置中管理。"
            : "Resets this app’s system privacy permissions. Keeps data, feature configuration, login items and hardware helpers. Grant access again for affected features; manage notifications in System Settings."
    }
    var resetFinished: String {
        chinese ? "系统权限重置完成，请重新启动 App 后按需授权。"
            : "System permissions reset. Restart the app and grant access as needed."
    }
    var resetFailed: String {
        chinese ? "权限重置未完成。部分输入功能已暂停，请重新启动 App，并检查系统设置后重试。"
            : "Permission reset did not complete. Some input features are paused. Restart the app, check System Settings and try again."
    }
}

struct PermissionsSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var refreshID = UUID()
    @State private var confirmingReset = false
    @State private var working = false
    @State private var resetResult: Bool?

    private var text: PermissionPageStrings { PermissionPageStrings(language: l10n.language) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text.title).font(.title2.bold())
                        Text(text.intro).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: refresh) {
                        Label(text.refresh, systemImage: "arrow.clockwise")
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                PermissionsPortalSections(hub: FeatureStrings.hub(l10n.language),
                                          compact: true, refreshID: refreshID)
            } footer: {
                Text(text.note).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.s.advancedResetSection).fontWeight(.medium)
                        Text(text.resetNote).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if working { ProgressView().controlSize(.small) }
                    Button(l10n.s.advancedClearButton, role: .destructive) {
                        confirmingReset = true
                    }
                }
                if let resetResult {
                    Text(resetResult ? text.resetFinished : text.resetFailed)
                        .font(.caption)
                        .foregroundStyle(resetResult ? Color.secondary : Color.orange)
                    Button(FeatureStrings.hub(l10n.language).restartButton) {
                        FeatureRuntime.shared.relaunchApp()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(working)
        .alert(l10n.s.advancedClearConfirmTitle, isPresented: $confirmingReset) {
            Button(l10n.s.uninstallerCancel, role: .cancel) {}
            Button(l10n.s.advancedClearButton, role: .destructive) {
                working = true
                resetResult = nil
                SelfUninstall.clearPermissions { success in
                    working = false
                    resetResult = success
                    refresh()
                }
            }
        } message: {
            Text(l10n.s.advancedClearConfirmBody + "\n\n" + text.resetNote)
        }
    }

    private func refresh() {
        Permissions.shared.refresh()
        refreshID = UUID()
    }
}
