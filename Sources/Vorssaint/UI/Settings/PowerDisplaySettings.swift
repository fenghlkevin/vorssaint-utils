import SwiftUI

struct PowerDisplayPanel: View {
    @ObservedObject private var manager = KeepAwakeManager.shared
    @ObservedObject private var displays = BrightnessService.shared
    @AppStorage(DefaultsKey.defaultDuration) private var duration = 60
    @AppStorage(DefaultsKey.brightnessControlEnabled) private var brightnessEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(manager.externalConnected ? "外接显示器已连接" : "使用内置显示器",
                      systemImage: manager.externalConnected ? "display.2" : "laptopcomputer")
                Spacer()
                Text(manager.onBattery ? "电池供电" : "接通电源").foregroundStyle(.secondary)
            }.font(.caption)
            Picker("空闲时", selection: Binding(get: { manager.temporaryMode ?? manager.effectiveMode },
                set: { manager.selectMode($0, minutes: duration) })) {
                ForEach(PowerIdleMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }.pickerStyle(.segmented)
            HStack {
                if manager.temporaryMode != nil {
                    Text("临时模式").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认策略") { manager.resumeDefaultPolicy() }.font(.caption)
                } else {
                    Text("当前使用\(manager.onBattery ? "电池" : "接电")默认策略")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if manager.temporaryMode != .system {
                HStack {
                    Text("本次持续").font(.caption)
                    Spacer()
                    DurationPicker(selection: $duration)
                }.onChange(of: duration) { _, value in
                    if let mode = manager.temporaryMode { manager.selectMode(mode, minutes: value) }
                }
                if let end = manager.endDate {
                    Text("\(end, style: .time) 恢复默认策略").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("合盖使用外屏", isOn: Binding(get: { manager.currentProfile.closedLid }, set: { enabled in
                var profile = manager.currentProfile
                profile.closedLid = enabled
                manager.updateProfile(profile, onBattery: manager.onBattery)
            })).toggleStyle(.switch).controlSize(.small)
            ClosedLidStatus()
            if AppFeature.brightness.isAvailable {
                Divider()
                if !brightnessEnabled {
                    Button("启用显示器控制") {
                        brightnessEnabled = true
                        displays.syncWithPreferences()
                    }
                } else {
                    ForEach(displays.displays) { display in
                        VStack(spacing: 4) {
                            HStack {
                                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                                Text(display.name).lineLimit(1)
                                Spacer()
                                Text(display.isActive ? "已开启" : "已关闭").foregroundStyle(.secondary)
                                DisplayPowerButton(display: display)
                            }.font(.caption)
                            if display.isActive, display.method != nil {
                                Slider(value: Binding(get: { display.brightness },
                                    set: { displays.setBrightness($0, for: display.id) }), in: 0...1)
                                    .controlSize(.small)
                                    .disabled(displays.isDisplayPending(display.id))
                                    .accessibilityLabel("\(display.name)亮度")
                            }
                        }
                    }
                    if let failure = displays.displayControlFailure {
                        Text(displayControlFailureText(failure, strings: FeatureStrings.brightness(L10n.shared.language)))
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Divider()
            HStack {
                Button { manager.lockScreen() } label: { Label("锁屏", systemImage: "lock") }
                Spacer()
                Button { manager.sleepNow() } label: {
                    Label(manager.sleepInProgress ? "正在准备休眠…" : "立即休眠", systemImage: "moon")
                }
            }.disabled(manager.sleepInProgress)
            if let error = manager.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            Button("电源与显示器设置…") {
                SettingsRouter.shared.request(FeatureSettingsDestination(.energy))
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            }.font(.caption)
        }
        .onAppear { manager.syncWithPreferences(); displays.refresh() }
    }
}

struct ClosedLidStatus: View {
    @ObservedObject private var manager = KeepAwakeManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if manager.clamshellSetupInProgress {
                Text("正在准备合盖授权…")
            } else if !manager.passwordlessClamshell || manager.clamshellSetupFailed {
                Button("授权合盖运行…") { manager.authorizeClosedLid() }
            } else {
                Text(manager.clamshellActive ? "已生效 · 合盖后外屏继续工作" : "已授权 · 按当前供电策略和外屏状态启用")
            }
            Text("仅连接外屏时生效；开启期间电脑不会自动休眠。需要睡眠时请用「立即休眠」。")
        }.font(.caption).foregroundStyle(.secondary)
    }
}

struct PowerDisplaySettingsSections: View {
    @ObservedObject private var manager = KeepAwakeManager.shared
    @State private var battery = true
    @State private var profile = PowerDisplayProfile()
    @AppStorage(DefaultsKey.batteryLimit) private var batteryLimit = 10
    @AppStorage(DefaultsKey.defaultDuration) private var duration = 60
    @AppStorage(DefaultsKey.keepAwakeAutoStart) private var launch = false
    @AppStorage(DefaultsKey.showCountdown) private var countdown = false
    @AppStorage(DefaultsKey.keepAwakeIconTint) private var tint = KeepAwakeIconTint.orange.rawValue
    @AppStorage(DefaultsKey.keepAwakeActiveIcon) private var icon = KeepAwakeActiveIcon.vorssaint.rawValue
    @AppStorage(DefaultsKey.keepAwakeRightClickToggle) private var rightClick = false
    @AppStorage(DefaultsKey.keepAwakeMouseJiggleEnabled) private var mouseJiggle = false
    @AppStorage(DefaultsKey.keepAwakeMouseJiggleInterval) private var jiggleInterval = 5

    var body: some View {
        Section("默认策略") {
            Picker("供电状态", selection: $battery) {
                Text("使用电池").tag(true)
                Text("接通电源").tag(false)
            }.pickerStyle(.segmented)
            Picker("空闲时", selection: binding(\.idle)) {
                ForEach(PowerIdleMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("连接外屏时", selection: binding(\.external)) {
                Text("沿用空闲设置").tag(Optional<PowerIdleMode>.none)
                ForEach(PowerIdleMode.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Toggle("合盖使用外屏", isOn: binding(\.closedLid))
            ClosedLidStatus()
            Text("运行可熄屏：电脑继续运行，显示器按系统设置熄灭。没有外屏时，合盖交由系统处理。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { battery = manager.onBattery; profile = PowerDisplayProfile.read(onBattery: battery) }
        .onChange(of: battery) { _, value in profile = PowerDisplayProfile.read(onBattery: value) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in
                let saved = PowerDisplayProfile.read(onBattery: battery)
                if saved != profile { profile = saved }
            }
        Section("显示器") {
            Toggle("连接外屏时自动关闭内屏", isOn: binding(\.hideInternal))
            Text("默认保留内外双屏。需启用下方显示器控制；拔掉外屏后恢复内屏，不能关闭最后一块可用屏幕。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("锁屏与休眠") {
            Picker("保持运行时锁屏后", selection: binding(\.locked)) {
                Text("沿用当前模式").tag(Optional<PowerIdleMode>.none)
                Text("继续运行，允许熄屏").tag(Optional(PowerIdleMode.awake))
                Text("跟随系统休眠").tag(Optional(PowerIdleMode.system))
            }
            Text("手动选择「立即休眠」会暂停本应用的防休眠控制；唤醒后恢复默认策略。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("锁屏") { manager.lockScreen() }
                Button(manager.sleepInProgress ? "正在准备休眠…" : "立即休眠") { manager.sleepNow() }
            }.disabled(manager.sleepInProgress)
            if let error = manager.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            if battery {
                Picker("低电量时恢复系统休眠", selection: $batteryLimit) {
                    Text("关闭").tag(0)
                    ForEach([5, 10, 15, 20], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
        }
        Section("菜单栏与快捷操作") {
            Picker("临时模式默认时长", selection: $duration) {
                Text("15 分钟").tag(15); Text("30 分钟").tag(30); Text("1 小时").tag(60)
                Text("2 小时").tag(120); Text("4 小时").tag(240); Text("8 小时").tag(480)
                Text("直到手动结束").tag(0)
            }
            Toggle("启动时开启临时保持唤醒", isOn: $launch)
            Toggle("菜单栏显示剩余时间", isOn: $countdown)
            Toggle("右键菜单栏图标切换保持唤醒", isOn: $rightClick)
            KeepAwakeIconPicker(iconValue: $icon, tintValue: $tint)
            Toggle("保持运行时轻微移动鼠标", isOn: $mouseJiggle)
            if mouseJiggle {
                Picker("移动间隔", selection: $jiggleInterval) {
                    ForEach(Defaults.allowedKeepAwakeMouseJiggleIntervals, id: \.self) { value in
                        Text("\(value) 分钟").tag(value)
                    }
                }
                PermissionRow(kind: .accessibility)
                Text("锁屏后暂停鼠标移动。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<PowerDisplayProfile, T>) -> Binding<T> {
        Binding(get: { profile[keyPath: keyPath] }, set: { value in
            profile[keyPath: keyPath] = value
            manager.updateProfile(profile, onBattery: battery)
        })
    }
}
