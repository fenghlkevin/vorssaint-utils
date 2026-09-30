// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import UniformTypeIdentifiers

struct AwayLockSettings: View {
    @ObservedObject private var service = AwayLockService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.awayLockEnabled) private var enabled = false
    @AppStorage(DefaultsKey.panelShowAwayLock) private var showInPanel = true
    @AppStorage(DefaultsKey.awayLockPeripheralID) private var peripheralID = ""
    @AppStorage(DefaultsKey.awayLockPeripheralName) private var peripheralName = ""
    @AppStorage(DefaultsKey.awayLockThreshold) private var threshold = -74
    @AppStorage(DefaultsKey.awayLockReturnMargin) private var returnMargin = 5
    @AppStorage(DefaultsKey.awayLockWeakSeconds) private var weakSeconds = 12
    @AppStorage(DefaultsKey.awayLockSignalLossSeconds) private var lossSeconds = 25
    @AppStorage(DefaultsKey.awayLockGraceSeconds) private var graceSeconds = 5
    @AppStorage(DefaultsKey.awayLockProtectRecentInput) private var protectInput = true
    @AppStorage(DefaultsKey.awayLockPreventPresentation) private var preventPresentation = true
    @AppStorage(DefaultsKey.awayLockWakeOnReturn) private var wakeOnReturn = false
    @AppStorage(DefaultsKey.awayLockAutomaticLock) private var automaticLock = true
    @AppStorage(DefaultsKey.awayLockShowCountdown) private var showCountdown = true
    @AppStorage(DefaultsKey.awayLockNotifications) private var notifications = true
    @AppStorage(DefaultsKey.awayLockNotificationSound) private var notificationSound = true
    @AppStorage(DefaultsKey.awayLockEnergyMode) private var energyMode = AwayLockEnergyMode.balanced.rawValue
    @AppStorage(DefaultsKey.awayLockShowUnnamedDevices) private var showUnnamedDevices = false
    @AppStorage(DefaultsKey.awayLockOnlySelectedDevices) private var onlySelectedDevices = false
    @State private var confirmSimulatedLock = false
    @State private var manualDeviceUUID = ""
    @State private var manualDeviceName = ""
    @State private var manualDeviceError: String?
    @State private var protectedAppIDs = UserDefaults.standard.stringArray(
        forKey: DefaultsKey.awayLockProtectedApps) ?? []

    private var strings: AwayLockStrings { .strings(for: l10n.language) }

    @AppStorage(DefaultsKey.awayLockAutoUnlock) private var autoUnlock = false
    @State private var showingPassword = false
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var passwordMessage: String?
    @State private var selectedTab = 0
    @State private var showingDevices = false
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.laptopcomputer")
                        .font(.system(size: 25)).foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(strings.title).font(.title2.bold())
                        Text("人离开，Mac 自动锁屏。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(strings.enable, isOn: $enabled).labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(strings.enable)
                }
                surface {
                    HStack(spacing: 10) {
                        Image(systemName: statusSymbol).foregroundStyle(statusColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(service.statusText).font(.headline)
                            Text(service.isPaused ? "暂停期间不会自动锁屏" : service.detailText)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(service.isPaused ? "恢复监测" : "暂停 30 分钟") {
                            service.isPaused ? service.resumeNow() : service.pause(minutes: 30)
                        }.disabled(!enabled)
                    }
                }
                Picker("设置分类", selection: $selectedTab) {
                    Text("常用设置").tag(0)
                    Text("高级与诊断").tag(1)
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                if selectedTab == 0 { commonSettings } else { advancedSettings }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingDevices) { deviceManager }
        .sheet(isPresented: $showingPassword, onDismiss: { password = ""; passwordConfirmation = "" }) { passwordSettings }
        .onChange(of: autoUnlock) { _, _ in service.syncReturnUnlockPreference() }
        .alert("完整模拟离开？", isPresented: $confirmSimulatedLock) {
            Button("取消", role: .cancel) { }
            Button("开始模拟") { service.simulateDeparture() }
        } message: {
            Text("此操作会真正锁屏：经过当前离开判定、提醒和倒计时后锁定 Mac。请停止操作，锁屏后手动唤醒或解锁恢复真实检测。")
        }
        .onAppear { service.syncWithPreferences(); permissions.refresh() }
        .onChange(of: wakeOnReturn) { _, _ in service.syncReturnWakePreference() }
        .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
        .onChange(of: threshold) { _, _ in service.syncWithPreferences() }
    }

    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func settingToggle(_ title: String, hint: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: value)
                .labelsHidden().toggleStyle(.switch).fixedSize()
                .accessibilityLabel(title)
                .accessibilityHint(hint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelVisibility: Binding<Bool> {
        Binding(get: { showInPanel }, set: { shown in
            guard shown || PanelLayout.order.contains(where: {
                $0 != .awayLock && $0.isAvailable && PanelLayout.isShown($0)
            }) else { return }
            showInPanel = shown
        })
    }

    private var commonSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text("跟随的设备").font(.headline); Spacer()
                    Button("管理设备…") { showingDevices = true }.buttonStyle(.link)
                }
                surface {
                    if service.selectedSignals.isEmpty {
                        Label("还没有选择设备", systemImage: "iphone.slash").foregroundStyle(.secondary)
                    }
                    ForEach(service.selectedSignals) { signal in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary)
                                .frame(width: 36, height: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(signal.name)
                                Text(service.primaryID == signal.id ? "主设备 · \(signal.status)" : signal.status)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(signal.rssi.map { "\($0) dBm" } ?? "等待信号")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Picker("锁屏条件", selection: Binding(get: { service.policy }, set: service.setPolicy)) {
                        ForEach(AwayLockPolicy.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("离开之后").font(.headline)
                surface {
                    settingToggle("自动锁屏", hint: "确认设备离开后，锁定当前 Mac", value: $automaticLock)
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            flowStep("01 · 检测", "信号变弱或失联")
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            flowStep("02 · 确认", "持续 \(weakSeconds) 秒")
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            flowStep("03 · 提醒", "\(graceSeconds) 秒后锁屏")
                        }
                        Text("信号变弱或失联 → 持续 \(weakSeconds) 秒 → \(graceSeconds) 秒后锁屏").font(.caption)
                    }
                    DisclosureGroup("调整距离与等待时间") {
                        VStack(spacing: 14) {
                            valueSlider("默认离开阈值", value: $threshold, range: -90 ... -55, suffix: "dBm")
                            Text("设备的自定义阈值优先于默认值，可在“管理设备”中调整。")
                                .font(.caption).foregroundStyle(.secondary)
                            valueSlider(strings.weakDuration, value: $weakSeconds, range: 5 ... 60, suffix: strings.seconds)
                            valueSlider(strings.grace, value: $graceSeconds, range: 3 ... 30, suffix: strings.seconds)
                        }.padding(.top, 12)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("回来之后").font(.headline)
                surface {
                    settingToggle("靠近时亮屏", hint: "仅尝试亮屏一次；使用 Apple Watch 解锁时，只需开启这一项。", value: $wakeOnReturn)
                    Divider()
                    settingToggle("自动输入密码解锁", hint: "仅在本程序锁屏后的设备返回时尝试一次。使用 Apple Watch 时可保持关闭。", value: Binding(get: { autoUnlock }, set: { value in
                        if value { passwordMessage = nil; showingPassword = true }
                        else { autoUnlock = false }
                    }))
                    HStack {
                        Button(autoUnlock ? "更新登录密码…" : "设置密码并启用…") { passwordMessage = nil; showingPassword = true }
                        Button("删除保存的密码", role: .destructive) {
                            autoUnlock = false
                            service.syncReturnUnlockPreference()
                            do { try AwayLockPassword.delete(); passwordMessage = "已删除保存的密码" }
                            catch { passwordMessage = error.localizedDescription }
                        }
                    }
                    Text("密码仅保存在本机钥匙串。开启密码解锁后，检测到设备靠近即可尝试登录；蓝牙距离不等同于身份验证。关闭亮屏时，仅在屏幕已经亮起的情况下尝试解锁。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = passwordMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if let status = service.unlockStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("显示与保护").font(.headline)
                surface {
                    settingToggle("在菜单面板中显示", hint: "隐藏分区不会停止监测；至少保留一个可见分区。", value: panelVisibility)
                    Divider()
                    settingToggle("使用电脑时暂缓锁屏", hint: "最近有键鼠操作时取消倒计时", value: $protectInput)
                    Divider()
                    settingToggle("全屏与会议保护", hint: "全屏或会议应用在前台时暂缓锁屏", value: $preventPresentation)
                    DisclosureGroup("自定义防误锁应用（\(protectedAppIDs.count)）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(sortedProtectedAppIDs, id: \.self) { protectedAppRow($0) }
                            Button("添加应用…") { addProtectedApplication() }
                        }.padding(.top, 8)
                    }
                }
            }
            HStack {
                if permissions.accessibility {
                    Label("辅助功能已授权", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                } else {
                    Button("授权辅助功能以使用自动锁屏") { Permissions.shared.requestAccessibility() }
                }
                Spacer()
                Button("预览锁屏倒计时") { AwayLockCountdownOverlay.shared.preview(seconds: graceSeconds) }
                    .disabled(!showCountdown)
            }.font(.caption)
        }
    }

    private var passwordSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置自动解锁密码").font(.title2.bold())
            Text("请输入当前 Mac 用户的登录密码。保存后启用自动输入；如果希望继续使用 Apple Watch，请取消并保持密码解锁关闭。")
                .foregroundStyle(.secondary)
            SecureField("Mac 登录密码", text: $password)
            SecureField("再次输入密码", text: $passwordConfirmation)
            Text("保存时不会验证密码。修改 Mac 登录密码后，需要在这里重新保存。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = passwordMessage { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { password = ""; passwordConfirmation = ""; showingPassword = false }
                Button("保存并启用") {
                    do {
                        service.syncReturnUnlockPreference()
                        try AwayLockPassword.save(password)
                        password = ""; passwordConfirmation = ""
                        autoUnlock = true
                        passwordMessage = "密码已保存到本机钥匙串"
                        showingPassword = false
                    } catch { passwordMessage = error.localizedDescription }
                }.disabled(password.isEmpty || password != passwordConfirmation)
            }
        }.padding(24).frame(width: 460)
    }

    private func flowStep(_ caption: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption2).foregroundStyle(.secondary)
            Text(title).font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("信号与扫描").font(.headline)
            surface {
                valueSlider(strings.lossDuration, value: $lossSeconds, range: 10 ... 90, suffix: strings.seconds)
                Divider()
                valueSlider("返回信号余量", value: $returnMargin, range: 2 ... 12, suffix: "dB")
                Picker("节能扫描", selection: $energyMode) {
                    ForEach(AwayLockEnergyMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Text("提醒").font(.headline)
            surface {
                settingToggle("锁屏倒计时弹窗", hint: "显示当前设置的 \(graceSeconds) 秒倒计时", value: $showCountdown)
                Divider()
                settingToggle("系统通知", hint: "离开锁屏前显示通知", value: $notifications)
                Divider()
                settingToggle("倒计时提示音", hint: "", value: $notificationSound)
            }
            HStack { Text("诊断与事件").font(.headline); Spacer()
                Button("复制全部日志") { service.copyEvents() }.disabled(service.events.isEmpty)
            }
            surface {
                HStack { Text(service.statusText); Spacer(); Text(service.detailText).foregroundStyle(.secondary) }
                DisclosureGroup("查看最近 20 条技术日志（共 \(service.events.count) 条）") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(service.events.prefix(20)) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Text(event.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                                Text(event.message).fixedSize(horizontal: false, vertical: true)
                            }.font(.caption).textSelection(.enabled)
                        }
                        Button("清空事件") { service.clearEvents() }.disabled(service.events.isEmpty)
                    }.padding(.top, 10)
                }
            }
            HStack {
                Button("完整模拟离开…") { confirmSimulatedLock = true }
                    .disabled(!enabled || !automaticLock || service.isSimulatingDeparture)
                if service.isSimulatingDeparture { Button("取消模拟") { service.cancelSimulatedDeparture() } }
                Spacer()
                Button("暂停到今天结束") { service.pauseForToday() }.disabled(!enabled)
            }
            Text("完整模拟会真正锁屏。只查看弹窗效果，请使用常用设置中的“预览锁屏倒计时”。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var deviceManager: some View {
        let devices = service.settingsDevices
        let visibleDevices = filteredDevices(from: devices)
        return VStack(alignment: .leading, spacing: 16) {
            HStack { Text("管理设备").font(.title2.bold()); Spacer()
                Button("完成") { showingDevices = false }.keyboardShortcut(.defaultAction)
            }
            Text("选择参与距离监测的设备，并设置主设备及自定义阈值。")
                .foregroundStyle(.secondary)
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
                            .frame(minHeight: 160, idealHeight: 260, maxHeight: 320)
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
        }.padding(24).frame(minWidth: 500, idealWidth: 580, maxWidth: 700)
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

    private var statusSymbol: String {
        switch service.state {
        case .nearby: return "checkmark.circle.fill"
        case .weak, .countdown: return "exclamationmark.triangle.fill"
        case .awaitingReturn: return "lock.fill"
        case .bluetoothUnavailable: return "antenna.radiowaves.left.and.right.slash"
        default: return "circle.dotted"
        }
    }

    private var statusColor: Color {
        if service.lockError != nil { return .red }
        if service.isPaused || !enabled { return .secondary }
        switch service.state {
        case .nearby: return .green
        case .weak, .countdown: return .orange
        case .awaitingReturn: return .blue
        case .bluetoothUnavailable: return .red
        default: return .secondary
        }
    }
}
