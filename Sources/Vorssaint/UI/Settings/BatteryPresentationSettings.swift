// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BatteryPresentationSettings: View {
    @AppStorage(DefaultsKey.batteryMenuHiddenFields) private var hidden = ""
    @AppStorage(DefaultsKey.batteryIconStyle) private var iconStyle = "dynamic"
    @AppStorage(DefaultsKey.batteryIconMonochrome) private var monochrome = true
    @AppStorage(DefaultsKey.batteryIconRemainingTime) private var remaining = false
    @AppStorage(DefaultsKey.batteryManagementNotifications) private var stateNotifications = false
    @AppStorage(DefaultsKey.batteryLowNotification) private var lowNotification = false
    @AppStorage(DefaultsKey.batteryLowNotificationThreshold) private var lowThreshold = 20

    var body: some View {
        Section("电池菜单内容") {
            ForEach(BatteryMenuField.allCases) { field in
                Toggle(field.title, isOn: Binding(get: { field.isVisible(hidden: hidden) },
                                                  set: { hidden = field.settingVisible($0, hidden: hidden) }))
            }
            Text("修改后立即生效。隐藏高能耗应用后，电池面板停止请求应用活跃度采样。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("电池状态图标") {
            Picker("样式", selection: $iconStyle) {
                Text("动态电池 + 状态标记").tag("dynamic")
                Text("简洁电池").tag("simple")
            }
            Toggle("单色图标", isOn: $monochrome)
            Toggle("显示预计剩余时间", isOn: $remaining)
            Text("保持隐藏电量百分比。剩余时间仅在使用电池且系统提供估算时显示。")
                .font(.caption).foregroundStyle(.secondary)
            Text("闪电：充电 · 暂停：暂停充电 · 向下箭头：放电 · 插头：接电未充电")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("电池通知") {
            Toggle("充电状态变化时通知", isOn: $stateNotifications)
            Toggle("低电量提醒", isOn: $lowNotification)
            if lowNotification {
                Stepper("电量低至 \(lowThreshold)%", value: $lowThreshold, in: 5...30, step: 5)
            }
            Text("按实际充电、放电和接电状态发送；首次采样不发送状态通知。低电量提醒每轮放电只发送一次。")
                .font(.caption).foregroundStyle(.secondary)
            Button("允许系统通知…") { Notifier.requestPermission() }
        }
    }
}
