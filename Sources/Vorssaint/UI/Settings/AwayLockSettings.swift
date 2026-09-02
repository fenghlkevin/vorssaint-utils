// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import UniformTypeIdentifiers

struct AwayLockSettings: View {
    @ObservedObject private var service = AwayLockService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.awayLockEnabled) private var enabled = false
    @AppStorage(DefaultsKey.awayLockPeripheralID) private var peripheralID = ""
    @AppStorage(DefaultsKey.awayLockPeripheralName) private var peripheralName = ""
    @AppStorage(DefaultsKey.awayLockThreshold) private var threshold = -74
    @AppStorage(DefaultsKey.awayLockReturnMargin) private var returnMargin = 5
    @AppStorage(DefaultsKey.awayLockWeakSeconds) private var weakSeconds = 12
    @AppStorage(DefaultsKey.awayLockSignalLossSeconds) private var lossSeconds = 25
    @AppStorage(DefaultsKey.awayLockGraceSeconds) private var graceSeconds = 5
    @AppStorage(DefaultsKey.awayLockProtectRecentInput) private var protectInput = true
    @AppStorage(DefaultsKey.awayLockPreventPresentation) private var preventPresentation = true
    @AppStorage(DefaultsKey.awayLockAutomaticLearning) private var automaticLearning = true
    @AppStorage(DefaultsKey.awayLockAutomaticLock) private var automaticLock = true
    @AppStorage(DefaultsKey.awayLockWakeOnReturn) private var wakeOnReturn = true
    @AppStorage(DefaultsKey.awayLockShowCountdown) private var showCountdown = true
    @AppStorage(DefaultsKey.awayLockNotifications) private var notifications = true
    @AppStorage(DefaultsKey.awayLockNotificationSound) private var notificationSound = true
    @AppStorage(DefaultsKey.awayLockEnergyMode) private var energyMode = AwayLockEnergyMode.balanced.rawValue
    @AppStorage(DefaultsKey.awayLockAutomaticScenes) private var automaticScenes = false
    @AppStorage(DefaultsKey.awayLockShowUnnamedDevices) private var showUnnamedDevices = false
    @AppStorage(DefaultsKey.awayLockOnlySelectedDevices) private var onlySelectedDevices = false
    @State private var profileName = ""
    @State private var manualDeviceUUID = ""
    @State private var manualDeviceName = ""
    @State private var manualDeviceError: String?
    @State private var protectedAppIDs = UserDefaults.standard.stringArray(
        forKey: DefaultsKey.awayLockProtectedApps) ?? []

    private var strings: AwayLockStrings { .strings(for: l10n.language) }

    var body: some View {
        let devices = service.settingsDevices
        let visibleDevices = filteredDevices(from: devices)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.laptopcomputer")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strings.title).font(.title2.bold())
                        Text(strings.caption).foregroundStyle(.secondary)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(strings.enable, isOn: $enabled)
                        Divider()
                        Text(strings.status).font(.headline)
                        Label(statusText, systemImage: statusSymbol)
                            .foregroundStyle(statusColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                GroupBox(strings.device) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("显示未命名设备", isOn: $showUnnamedDevices).toggleStyle(.checkbox)
                            Toggle("仅显示已选设备", isOn: $onlySelectedDevices).toggleStyle(.checkbox)
                            Spacer()
                            if visibleDevices.count != devices.count {
                                Text("已隐藏 \(devices.count - visibleDevices.count) 台")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if devices.isEmpty {
                            Text(enabled ? strings.searching : strings.noDevice).foregroundStyle(.secondary)
                        } else if visibleDevices.isEmpty {
                            Text("没有符合当前筛选条件的设备").foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(visibleDevices) { device in deviceRow(device) }
                                }
                            }
                            .frame(height: 240)
                        }
                        HStack { Text("已选择 \(service.selectedIDs.count) 台").foregroundStyle(.secondary); Spacer()
                            Button(service.isRescanning ? "扫描中…" : "重新扫描") { service.rescan() }.disabled(service.isRescanning)
                            Button("清理旧设备") { service.removeStaleDevices() }
                        }.font(.caption)
                        DisclosureGroup("通过设备标识符添加") {
                            VStack(alignment: .leading, spacing: 7) {
                                TextField("CoreBluetooth UUID", text: $manualDeviceUUID)
                                    .textFieldStyle(.roundedBorder)
                                TextField("设备名称（可选）", text: $manualDeviceName)
                                    .textFieldStyle(.roundedBorder)
                                HStack {
                                    Button("添加设备") { addManualDevice() }
                                    if let manualDeviceError { Text(manualDeviceError).foregroundStyle(.red) }
                                }
                                Text("macOS 不向 App 提供 BLE 设备的真实 MAC 地址。这里填写的是本机分配的 CoreBluetooth UUID；添加后仍需后台扫描才能获得距离信号。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 6)
                        }
                        Picker("多设备策略", selection: Binding(get: { service.policy }, set: service.setPolicy)) {
                            ForEach(AwayLockPolicy.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        valueSlider(strings.threshold, value: $threshold, range: -90 ... -55, suffix: "dBm")
                        valueSlider("Return margin", value: $returnMargin, range: 2 ... 12, suffix: "dB")
                        valueSlider(strings.weakDuration, value: $weakSeconds, range: 5 ... 60, suffix: strings.seconds)
                        valueSlider(strings.lossDuration, value: $lossSeconds, range: 10 ... 90, suffix: strings.seconds)
                        valueSlider(strings.grace, value: $graceSeconds, range: 3 ... 30, suffix: strings.seconds)
                        Toggle(strings.protectInput, isOn: $protectInput)
                        Toggle("全屏与会议应用防误锁", isOn: $preventPresentation)
                        if protectedAppIDs.isEmpty {
                            Text("尚未添加自定义防误锁应用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("已防误锁应用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(sortedProtectedAppIDs, id: \.self) { bundleID in
                                    protectedAppRow(bundleID)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("添加防误锁应用…") { addProtectedApplication() }
                        Picker("自适应节能扫描", selection: $energyMode) {
                            ForEach(AwayLockEnergyMode.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                GroupBox("校准与自动学习") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(service.calibrationMessage).foregroundStyle(.secondary)
                        HStack { Button("采集座位信号") { service.startNearCalibration() }
                            Button("采集离席信号") { service.startFarCalibration() } }
                        Toggle("逐设备自动学习阈值", isOn: $automaticLearning)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("场景配置") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("新场景名称", text: $profileName)
                            Button("保存当前配置") { if !profileName.isEmpty { service.addProfile(named: profileName); profileName = "" } }
                        }
                        ForEach(service.profiles) { profile in
                            HStack { Text(profile.name); Spacer(); Button("应用") { service.applyProfile(profile.id) }
                                if service.activeProfileID == profile.id { Button("更新") { service.updateActiveProfile() }; Button("删除") { service.deleteActiveProfile() } }
                            }.font(.caption)
                        }
                        Toggle("根据 Wi‑Fi 与电源自动切换", isOn: $automaticScenes)
                        Text("当前：\(service.currentWiFiName) · \(service.currentPowerName)").font(.caption).foregroundStyle(.secondary)
                        Button("把当前环境绑定到当前场景") { service.bindCurrentEnvironment() }.disabled(service.activeProfileID == nil)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("系统与提醒") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("自动锁屏", isOn: $automaticLock)
                        Toggle("设备靠近时唤醒显示器", isOn: $wakeOnReturn)
                        Toggle("锁屏前显示 5 秒倒计时弹窗", isOn: $showCountdown)
                        Text("关闭后仍会按离开规则自动锁屏，但不会弹出倒计时窗口。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("预览倒计时弹窗") {
                            AwayLockCountdownOverlay.shared.preview(seconds: graceSeconds)
                        }
                        .disabled(!showCountdown)
                        Toggle("系统通知", isOn: $notifications)
                        Toggle("倒计时提示音", isOn: $notificationSound)
                        HStack { Button("暂停 30 分钟") { service.pause(minutes: 30) }
                            Button("暂停到今天结束") { service.pauseForToday() }
                            if service.isPaused { Button("立即恢复") { service.resumeNow() } }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("诊断与事件") {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text("当前信号"); Spacer(); Text(service.latestAggregateRSSI.map { "\($0) dBm" } ?? "—") }
                        HStack { Text("监测状态"); Spacer(); Text(service.statusText) }
                        Divider()
                        ForEach(service.events.prefix(20)) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Text(event.date.formatted(date: .omitted, time: .standard))
                                    .monospacedDigit()
                                Text(event.message).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.font(.caption).textSelection(.enabled)
                        }
                        HStack {
                            Button("复制全部日志") { service.copyEvents() }.disabled(service.events.isEmpty)
                            Button("清空事件") { service.clearEvents() }.disabled(service.events.isEmpty)
                            Text("显示最近 20 条，共 \(service.events.count) 条（最多保留 1000 条）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(24)
        }
        .onAppear { service.syncWithPreferences() }
        .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
        .onChange(of: threshold) { _, _ in service.syncWithPreferences() }
    }

    private func valueSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue) \(suffix)").monospacedDigit() }
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound) ... Double(range.upperBound), step: 1)
        }
    }

    private func filteredDevices(from devices: [AwayLockPeripheral]) -> [AwayLockPeripheral] {
        let selectedIDs = service.selectedIDs
        return devices.filter { device in
            let selected = selectedIDs.contains(device.id.uuidString)
            let hasName = device.name != "未命名设备"
                && !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (showUnnamedDevices || hasName || selected) && (!onlySelectedDevices || selected)
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: AwayLockPeripheral) -> some View {
        let id = device.id.uuidString
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle(isOn: Binding(get: { service.selectedIDs.contains(id) },
                                     set: { _ in service.toggleDevice(device) })) {
                    Text(service.displayName(id)).lineLimit(1)
                }.toggleStyle(.checkbox)
                Spacer()
                Text(device.lastSeen == .distantPast ? "等待信号" : "\(device.rssi) dBm")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { rename(device) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("自定义设备名称")
                Button { service.setPrimary(id) } label: {
                    Image(systemName: service.primaryID == id ? "star.fill" : "star")
                        .foregroundStyle(service.primaryID == id ? .yellow : .secondary)
                }.buttonStyle(.plain).disabled(!service.selectedIDs.contains(id)).help("设为主设备")
            }
            Text(id).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            if service.selectedIDs.contains(id) {
                HStack {
                    Toggle("自定义阈值", isOn: Binding(get: { service.hasCustomThreshold(id) },
                                                       set: { service.setThreshold($0 ? service.threshold(for: id) : nil, for: id) }))
                        .toggleStyle(.checkbox).font(.caption)
                    if service.hasCustomThreshold(id) {
                        Slider(value: Binding(get: { Double(service.threshold(for: id)) },
                                              set: { service.setThreshold(Int($0), for: id) }),
                               in: -90 ... -55, step: 1)
                        Text("\(service.threshold(for: id)) dBm").font(.caption.monospacedDigit()).frame(width: 62)
                    } else {
                        Spacer()
                        Text("\(service.thresholdSource(id)) · \(service.threshold(for: id)) dBm")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.padding(.leading, 22)
            }
        }.padding(.vertical, 4)
    }

    private func rename(_ device: AwayLockPeripheral) {
        let alert = NSAlert(); alert.messageText = "自定义设备名称"
        let field = NSTextField(string: service.displayName(device.id.uuidString)); field.frame.size.width = 260
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { service.setAlias(field.stringValue, for: device.id.uuidString) }
    }

    private func addProtectedApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !protectedAppIDs.contains(id) {
                protectedAppIDs.append(id)
            }
        }
        saveProtectedApplications()
    }

    private var sortedProtectedAppIDs: [String] {
        protectedAppIDs.sorted {
            InstalledApps.name(for: $0)
                .localizedCaseInsensitiveCompare(InstalledApps.name(for: $1)) == .orderedAscending
        }
    }

    private func protectedAppRow(_ bundleID: String) -> some View {
        HStack(spacing: 9) {
            Image(nsImage: InstalledApps.icon(for: bundleID))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(InstalledApps.name(for: bundleID))
                Text(bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                protectedAppIDs.removeAll { $0 == bundleID }
                saveProtectedApplications()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除防误锁应用")
        }
        .padding(.vertical, 2)
    }

    private func saveProtectedApplications() {
        UserDefaults.standard.set(protectedAppIDs, forKey: DefaultsKey.awayLockProtectedApps)
    }

    private func addManualDevice() {
        guard let id = UUID(uuidString: manualDeviceUUID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            manualDeviceError = "UUID 格式不正确"; return
        }
        service.addDevice(identifier: id, name: manualDeviceName)
        manualDeviceUUID = ""; manualDeviceName = ""; manualDeviceError = nil
    }

    private var statusText: String {
        switch service.state {
        case .disabled: return strings.enable
        case .needsDevice: return strings.noDevice
        case .scanning: return strings.searching
        case .nearby(let rssi): return "Nearby · \(rssi) dBm"
        case .weak(let seconds): return "Weak signal · \(seconds) \(strings.seconds)"
        case .countdown(let seconds): return "Locking in \(seconds) \(strings.seconds)"
        case .bluetoothUnavailable: return strings.bluetoothUnavailable
        }
    }

    private var statusSymbol: String {
        switch service.state {
        case .nearby: return "checkmark.circle.fill"
        case .weak, .countdown: return "exclamationmark.triangle.fill"
        case .bluetoothUnavailable: return "antenna.radiowaves.left.and.right.slash"
        default: return "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch service.state {
        case .nearby: return .green
        case .weak, .countdown: return .orange
        case .bluetoothUnavailable: return .red
        default: return .secondary
        }
    }
}
