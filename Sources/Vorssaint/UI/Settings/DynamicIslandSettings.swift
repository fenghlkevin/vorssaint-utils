import AppKit
import SwiftUI

struct DynamicIslandSettings: View {
    private enum SettingsTab: String, CaseIterable { case general = "通用", aiHook = "AI Hook", music = "音乐", timer = "定时器" }
    @ObservedObject private var service = DynamicIslandService.shared
    @ObservedObject private var reminders = TimeReminderService.shared
    @ObservedObject private var codex = CodexIslandService.shared
    @State private var selectedSettingsTab: SettingsTab = .aiHook

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Picker("", selection: $selectedSettingsTab) {
                    ForEach(SettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 470)
                .padding(.bottom, 2)
                if selectedSettingsTab == .general {
                settingsCard {
                    settingRow(icon: "power", tint: .blue, title: "启用灵动岛", detail: "在屏幕顶部显示音乐控制和时间提醒") {
                        Toggle("", isOn: $service.enabled).labelsHidden()
                    }
                }
                sectionTitle("显示")
                settingsCard {
                    settingRow(icon: "display", tint: .indigo, title: "显示位置", detail: "活动显示器会跟随最后一次鼠标点击") {
                        Picker("", selection: $service.selectedDisplay) {
                            Text("活动显示器").tag("active")
                            ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                        }.labelsHidden().frame(width: 170)
                    }
                }
                sectionTitle("显示的 Tab")
                settingsCard {
                    tabVisibilityRow("AI Hook", symbol: "terminal.fill", color: .blue, isOn: $service.showAIHookTab)
                    Divider().padding(.leading, 58)
                    tabVisibilityRow("音乐", symbol: "music.note", color: .pink, isOn: $service.showMusicTab)
                    Divider().padding(.leading, 58)
                    tabVisibilityRow("定时器", symbol: "timer", color: .orange, isOn: $service.showTimerTab)
                    Divider().padding(.leading, 58)
                    tabVisibilityRow("备忘", symbol: "square.and.pencil", color: .green, isOn: $service.showMemoTab)
                }
                sectionTitle("集成")
                settingsCard {
                    settingRow(icon: "terminal.fill", tint: .blue, title: "AI Hook", detail: codex.lastError ?? (codex.hookInstalled ? "已连接 Codex，正在接收 AI 任务状态" : "启用后显示 AI 任务状态")) {
                        Toggle("", isOn: $codex.enabled).labelsHidden()
                    }
                }
                }
                if selectedSettingsTab == .aiHook {
                moduleHeader("AI Hook", detail: "管理 AI 会话的显示、通知、过滤与声音", symbol: "terminal.fill", color: .blue)
                sectionTitle("显示 · 实时预览")
                codexPreview
                sectionTitle("显示 · 会话卡片")
                settingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text("显示模式").font(.body.weight(.medium)); Text("简洁模式仅显示最重要的一条会话").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Picker("", selection: $codex.displayMode) { Text("简洁").tag("compact"); Text("详细").tag("detailed") }
                            .pickerStyle(.segmented).frame(width: 150)
                    }.padding(16)
                    Divider().padding(.leading, 58)
                    settingRow(icon: "folder.fill", tint: .blue, title: "显示项目名称", detail: "在会话标题前显示所属项目") {
                        Toggle("", isOn: $codex.showProjectName).labelsHidden()
                    }
                    Divider().padding(.leading, 58)
                    settingRow(icon: "waveform.path.ecg", tint: .green, title: "显示活动详情", detail: "显示分析、工具执行和结果整理状态") {
                        Toggle("", isOn: $codex.showActivityDetail).labelsHidden()
                    }
                    Divider().padding(.leading, 58)
                    settingRow(icon: "person.2.fill", tint: .purple, title: "显示子 Agent", detail: "显示 Codex 子任务和并行 Agent 活动") {
                        Toggle("", isOn: $codex.showSubagents).labelsHidden()
                    }
                }
                sectionTitle("显示 · 面板尺寸")
                settingsCard {
                    sliderRow("内容字体", value: $codex.contentFontSize, range: 10...15, suffix: "pt")
                    Divider().padding(.leading, 16)
                    sliderRow("最大宽度", value: $codex.panelWidth, range: 520...760, suffix: "pt")
                    Divider().padding(.leading, 16)
                    sliderRow("最大高度", value: $codex.panelHeight, range: 220...560, suffix: "pt")
                }
                sectionTitle("通知 · 完成与子任务")
                settingsCard {
                    settingRow(icon: "rectangle.expand.vertical", tint: .orange, title: "收到完成通知时展开", detail: "关闭后保持收起；审批仍会立即展开") {
                        Toggle("", isOn: $codex.expandOnCompletion).labelsHidden()
                    }
                    Divider().padding(.leading, 58)
                    HStack { Text("子 Agent 与 Agent Team 通知"); Spacer(); Picker("", selection: $codex.subagentNotification) { Text("主 Agent 回复时").tag("main"); Text("立即通知").tag("immediate") }.labelsHidden().frame(width: 170) }
                        .padding(16)
                }
                sectionTitle("通知 · 场景自动静默")
                settingsCard {
                    settingRow(icon: "lock.fill", tint: .gray, title: "锁屏或屏幕睡眠", detail: "此时不自动出声，完成状态仍会保留") {
                        Toggle("", isOn: $codex.muteWhileLocked).labelsHidden()
                    }
                }
                sectionTitle("通知 · 会话过滤")
                settingsCard {
                    settingRow(icon: "line.3.horizontal.decrease.circle.fill", tint: .indigo, title: "内置过滤", detail: "隐藏 Codex 记忆写入、推荐提示和 Git 文案等后台会话") {
                        Toggle("", isOn: $codex.builtInFiltersEnabled).labelsHidden()
                    }
                    Divider().padding(.leading, 58)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("隐藏目录").font(.body.weight(.medium))
                        TextField("逗号分隔，例如 /.codex/memories", text: $codex.pathFilters).textFieldStyle(.roundedBorder)
                        Text("工作目录包含任意片段时隐藏").font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                    Divider().padding(.leading, 58)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("隐藏提示词").font(.body.weight(.medium))
                        TextField("逗号分隔的提示词前缀", text: $codex.promptFilters).textFieldStyle(.roundedBorder)
                        Text("首条提示词匹配任意前缀时隐藏").font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                }
                sectionTitle("声音 · AI Hook 提示音")
                settingsCard {
                    settingRow(icon: "speaker.wave.2.fill", tint: .purple, title: "任务事件提示音", detail: "会话开始、任务完成、错误和等待审批时播放") {
                        Toggle("", isOn: $codex.soundEnabled).labelsHidden()
                    }
                    if codex.soundEnabled {
                        Divider().padding(.leading, 58)
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $codex.soundVolume, in: 0.05...1)
                            Text("\(Int((codex.soundVolume * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                        Divider().padding(.leading, 58)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            soundPreview("会话开始", symbol: "play.fill", color: .blue, kind: .started)
                            soundPreview("任务完成", symbol: "checkmark", color: .green, kind: .completed)
                            soundPreview("任务错误", symbol: "xmark", color: .red, kind: .failed)
                            soundPreview("等待审批", symbol: "exclamationmark", color: .orange, kind: .waiting)
                        }.padding(12)
                    }
                }
                }
                if selectedSettingsTab == .music {
                    moduleHeader("音乐", detail: "管理系统媒体和 Apple Music 播放控制", symbol: "music.note", color: .pink)
                    sectionTitle("音乐控制")
                    settingsCard {
                        settingRow(icon: "music.note", tint: .pink, title: "系统媒体控制", detail: "显示当前媒体、播放控制、进度和音量") {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Divider().padding(.leading, 58)
                        settingRow(icon: "music.note.house.fill", tint: .red, title: "Apple Music", detail: "未启动时也显示音乐入口，点击播放会自动启动") {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                if selectedSettingsTab == .timer {
                moduleHeader("定时器", detail: "管理倒计时、专注、日程和休息提醒", symbol: "timer", color: .orange)
                sectionTitle("自动提醒")
                settingsCard {
                    settingRow(icon: "calendar", tint: .blue, title: "日程提醒", detail: "日程开始前 10 分钟自动展开灵动岛") {
                        Toggle("", isOn: $reminders.calendarEnabled).labelsHidden()
                    }
                    Divider().padding(.leading, 58)
                    settingRow(icon: "figure.cooldown", tint: .green, title: "休息提醒", detail: reminders.breakEnabled ? "连续工作 \(reminders.breakMinutes) 分钟后提醒" : "根据连续工作时间提醒休息") {
                        Toggle("", isOn: $reminders.breakEnabled).labelsHidden()
                    }
                    if reminders.breakEnabled {
                        Divider().padding(.leading, 58)
                        HStack { Text("提醒间隔").foregroundStyle(.secondary); Spacer(); Stepper("\(reminders.breakMinutes) 分钟", value: $reminders.breakMinutes, in: 10...120, step: 5) }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    Divider().padding(.leading, 58)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("完成提示时长").font(.body.weight(.medium))
                            Text("倒计时或专注结束后自动展开的时间").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper("\(reminders.completionDisplaySeconds) 秒", value: $reminders.completionDisplaySeconds, in: 5...60, step: 5)
                    }.padding(16)
                    Divider().padding(.leading, 58)
                    settingRow(icon: "speaker.wave.2.fill", tint: .orange, title: "提醒铃声", detail: "倒计时、专注、日程和休息提醒时播放提示音") {
                        Toggle("", isOn: $reminders.completionSoundEnabled).labelsHidden()
                    }
                    if reminders.completionSoundEnabled {
                        Divider().padding(.leading, 58)
                        HStack {
                            Text("提示音").foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $reminders.completionSoundName) {
                                ForEach(["Glass", "Ping", "Pop", "Purr", "Submarine", "Tink"], id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 150)
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                        Divider().padding(.leading, 58)
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $reminders.completionSoundVolume, in: 0.05...1)
                            Text("\(Int((reminders.completionSoundVolume * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                            Button("试听") { reminders.previewCompletionSound() }
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
                Text("倒计时和专注模式可直接在灵动岛的时间页中创建。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
            }.padding(24).frame(maxWidth: 760)
        }.navigationTitle("灵动岛")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "capsule.inset.filled").font(.system(size: 26)).foregroundStyle(.white)
                .frame(width: 52, height: 52).background(.black, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) { Text("灵动岛").font(.title2.weight(.semibold)); Text("集中管理音乐、倒计时和重要提醒").foregroundStyle(.secondary) }
        }
    }
    private func tabVisibilityRow(_ title: String, symbol: String, color: Color, isOn: Binding<Bool>) -> some View {
        settingRow(icon: symbol, tint: color, title: title, detail: "在灵动岛顶部显示此 Tab") {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .disabled(isOn.wrappedValue && service.visibleTabCount == 1)
        }
    }
    private var codexPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CodexActivityIndicator(status: .running)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if codex.showProjectName {
                            Text("vorssaint-utils").foregroundStyle(.white.opacity(0.55))
                            Text("·").foregroundStyle(.white.opacity(0.3))
                        }
                        Text("优化 Codex 灵动岛的显示与通知").foregroundStyle(.white)
                    }
                    if codex.showActivityDetail {
                        Text("正在整理结果").foregroundStyle(.white.opacity(0.58))
                    }
                }
                .font(.custom("Departure Mono", size: codex.contentFontSize))
                Spacer()
                Text("Codex").font(.system(size: 9, weight: .medium)).foregroundStyle(.blue)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                Text("刚刚").font(.caption2).foregroundStyle(.white.opacity(0.45))
                Circle().fill(.blue).frame(width: 7, height: 7)
            }.padding(.horizontal, 18).frame(height: codex.displayMode == "compact" ? 58 : 68)
            if codex.displayMode == "detailed", codex.showSubagents {
                Divider().overlay(.white.opacity(0.1)).padding(.leading, 52)
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.purple).frame(width: 34)
                    Text("Agent · 检查任务状态事件").font(.custom("Departure Mono", size: max(9, codex.contentFontSize - 1)))
                    Spacer(); Text("完成").font(.caption2).foregroundStyle(.green)
                }.padding(.horizontal, 18).frame(height: 44)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 0))
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.headline).padding(.horizontal, 4).padding(.bottom, -8) }
    private func moduleHeader(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(color, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.top, 2)
    }
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06)))
    }
    private func settingRow<Trailing: View>(icon: String, tint: Color, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.white).frame(width: 30, height: 30).background(tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.body.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer(); trailing()
        }.padding(16)
    }
    private func soundPreview(_ title: String, symbol: String, color: Color, kind: CodexIslandService.SoundKind) -> some View {
        Button { codex.preview(kind) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 76, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue.rounded()))\(suffix)").monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
        }.padding(.horizontal, 16).padding(.vertical, 11)
    }
}
