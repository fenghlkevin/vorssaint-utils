// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct AwayLockPanelCard: View {
    @ObservedObject private var service = AwayLockService.shared
    @AppStorage(DefaultsKey.awayLockEnabled) private var enabled = false
    @AppStorage(DefaultsKey.awayLockWakeOnReturn) private var wakeOnReturn = false
    @AppStorage(DefaultsKey.awayLockAutoUnlock) private var autoUnlock = false
    @State private var pauseDuration = 30
    @State private var needsPasswordSetup = false
    let collapsible: Bool

    var body: some View {
        PanelSection(.awayLock, title: AwayLockStrings.current.title, collapsible: collapsible) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(statusColor)
                        .frame(width: 42, height: 42)
                        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.statusText).font(.system(size: 14, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(service.isPaused ? "暂停期间不会自动锁屏" : (autoUnlock ? "离开自动锁屏，返回尝试密码解锁" : "离开自动锁屏，返回由手表或手动解锁"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("启用距离监测", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("启用距离监测")
                }
                if service.selectedSignals.isEmpty {
                    Button("选择要跟随的设备…") { openSettings() }.buttonStyle(.bordered)
                } else {
                    VStack(spacing: 10) {
                        ForEach(service.selectedSignals) { signal in
                            HStack(spacing: 10) {
                                Image(systemName: "iphone").font(.title3).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(signal.name).lineLimit(1)
                                    Text(service.primaryID == signal.id ? "主设备 · \(signal.status)" : signal.status)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(signal.rssi.map { "\($0) dBm" } ?? "等待信号")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                    }.padding(12).frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                optionRow("靠近时亮屏", systemImage: "sun.max", isOn: $wakeOnReturn)
                optionRow("自动输入密码解锁", systemImage: "key", isOn: Binding(get: { autoUnlock }, set: { requested in
                    if !requested {
                        autoUnlock = false
                        service.syncReturnUnlockPreference()
                    } else if let password = try? AwayLockPassword.read(), !password.isEmpty {
                        autoUnlock = true
                        service.syncReturnUnlockPreference()
                    } else {
                        needsPasswordSetup = true
                    }
                }))
                HStack(spacing: 8) {
                    Button {
                        if service.isPaused { service.resumeNow() }
                        else if pauseDuration == -1 { service.pauseForToday() }
                        else { service.pause(minutes: pauseDuration) }
                    } label: {
                        Label(service.isPaused ? "恢复监测" : "暂停监测",
                              systemImage: service.isPaused ? "play" : "pause")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(!enabled)
                    Picker("暂停时长", selection: $pauseDuration) {
                        Text("30 分钟").tag(30)
                        Text("1 小时").tag(60)
                        Text("今天结束").tag(-1)
                    }.labelsHidden().fixedSize().disabled(service.isPaused || !enabled)
                }
                Text(autoUnlock ? "返回后尝试密码解锁一次" : (wakeOnReturn ? "返回后尝试亮屏一次 · 由手表或手动解锁" : "返回后手动唤醒"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
            .onChange(of: wakeOnReturn) { _, _ in service.syncReturnWakePreference() }
            .alert("请先设置登录密码", isPresented: $needsPasswordSetup) {
                Button("取消", role: .cancel) { }
                Button("前往设置") { openSettings() }
            } message: {
                Text("尚未保存可读取的登录密码，请到“回来之后”设置密码并启用。使用 Apple Watch 解锁时，保持此开关关闭即可。")
            }
        }
    }

    private func optionRow(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 30)
    }

    private func openSettings() {
        SettingsRouter.shared.request(AppFeature.awayLock.settingsDestination)
        appDelegate()?.openSettingsWindow()
    }

    private var statusSymbol: String {
        if service.isPaused { return "pause.fill" }
        switch service.state {
        case .nearby: return "lock.open.fill"
        case .weak, .countdown: return "exclamationmark.lock.fill"
        case .bluetoothUnavailable: return "antenna.radiowaves.left.and.right.slash"
        default: return "lock.fill"
        }
    }

    private var statusColor: Color {
        if service.lockError != nil { return .red }
        if service.isPaused || !enabled { return .secondary }
        switch service.state {
        case .nearby: return .green
        case .weak, .countdown: return .orange
        case .bluetoothUnavailable: return .red
        default: return .secondary
        }
    }
}
