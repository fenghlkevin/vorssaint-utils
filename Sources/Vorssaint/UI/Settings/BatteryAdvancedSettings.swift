// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BatteryAdvancedSettings: View {
    @ObservedObject private var service = BatteryManagementService.shared
    @ObservedObject private var automation = BatteryAutomationService.shared
    @AppStorage("batteryManagement.dischargeAboveLimit") private var discharge = false
    @AppStorage("batteryManagement.preventSleepDischarging") private var awakeDischarging = false
    @AppStorage("batteryManagement.preventSleepCharging") private var awakeCharging = false
    @AppStorage("batteryManagement.greenLED") private var greenLED = false
    @AppStorage("batteryManagement.blinkLED") private var blinkLED = false
    @State private var editing: BatteryAutomationRule?

    var body: some View {
        Section("电池诊断与事件") {
            DisclosureGroup("最近电池采样（电流 / 功率 / 电量变化）") {
                Text(service.latestPowerObservation ?? "等待本次启动后的电池采样；历史采样可在诊断报告查看。")
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("最近日志") {
                ForEach(Array(service.diagnosticEvents.prefix(20).enumerated()), id: \.offset) { _, entry in
                    Text(entry).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("复制全部日志") { service.copyDiagnosticEvents() }
                Button("清空全部日志") { service.clearDiagnosticEvents() }
                Text("连接事件 \(service.diagnosticEvents.count)/1000；电池采样另存最近3000条，复制时一并导出；重启后保留")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !service.systemChargeLimitBackend {
        Section("充放电与睡眠") {
            Toggle("超过充电上限时主动放电至上限", isOn: $discharge)
                .disabled(service.backendReady && !service.dischargeSupported)
            Toggle("允许合盖外接显示器模式继续主动放电", isOn: $awakeDischarging)
                .disabled(service.backendReady && !service.dischargeSupported)
            Toggle("充电未到上限时延缓自动睡眠", isOn: $awakeCharging)
            Text("开启后，主动放电期间同时防止空闲睡眠和系统睡眠；达到充电上限、停止放电、电池后台断开或单次达到 4 小时时立即恢复正常睡眠。手动选择睡眠仍会终止本次主动放电。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("MagSafe 灯效") {
            Toggle("暂停充电时显示绿色 LED", isOn: $greenLED)
            Toggle("开始主动放电时 LED 闪烁提示", isOn: $blinkLED)
            Text(service.backendReady ? (service.ledSupported
                ? "已检测到 LED 控制接口；仅带灯的 MagSafe 连接可见，USB-C 不显示灯效。"
                : "当前机型未检测到兼容 LED 控制接口。") : "授权电池后台后检测支持状态。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(service.backendReady && !service.ledSupported)
        }
        Section("充电自动化") {
            Toggle("启用时间 / 地点规则", isOn: $automation.enabled)
            Text(service.systemChargeLimitBackend
                 ? "每 30 秒及唤醒时匹配首条规则；仅支持系统报告的上限档位，不支持的值会报错，不会自动提高目标。睡眠中沿用系统策略，不切换规则。"
                 : "按从上到下的顺序匹配第一条规则；无匹配时使用基础上限。每 30 秒及唤醒时检查；睡眠中暂停充电，不执行时间/地点切换。")
                .font(.caption).foregroundStyle(.secondary)
            if let rule = service.activeRule { Label("当前规则：\(rule) · \(service.effectiveLimit)%", systemImage: "checkmark.circle") }
            if automation.rules.isEmpty { Text("暂无规则，可以按星期、时段和地点设置上限。").foregroundStyle(.secondary) }
            ForEach(Array(automation.rules.enumerated()), id: \.element.id) { index, rule in
                HStack {
                    Toggle(isOn: Binding(get: { rule.enabled }, set: { value in
                        if let i = automation.rules.firstIndex(where: { $0.id == rule.id }) { automation.rules[i].enabled = value }
                    })) { Text("\(rule.name) · \(rule.limit)%") }
                    Spacer()
                    Button { automation.rules.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("提高优先级")
                    Button { automation.rules.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index + 1 == automation.rules.count).help("降低优先级")
                    Button("编辑") { editing = rule }
                    Button(role: .destructive) { automation.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                }
            }
            Button("添加规则…") { editing = BatteryAutomationRule() }
            Text(automation.locationMessage).font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { rule in
            BatteryRuleEditor(rule: rule) { updated in
                if let index = automation.rules.firstIndex(where: { $0.id == updated.id }) { automation.rules[index] = updated }
                else { automation.rules.append(updated) }
            }
        }
    }
}

struct BatteryTakeoverButton: View {
    @ObservedObject private var service = BatteryManagementService.shared
    @State private var confirming = false
    var body: some View {
        if service.needsTakeover {
            Button("接管充电管理…") { confirming = true }
                .disabled(service.performingUserAction)
                .alert("确认接管现有充电限制？", isPresented: $confirming) {
                    Button("取消", role: .cancel) {}
                    Button("确认接管") { service.takeOver() }
                } message: {
                    Text("请先退出 BatFi、AlDente 等其他充电工具。Vorssaint 将按当前设置管理充电，并在退出或断连时恢复系统自动充电。")
                }
        }
    }
}

private struct BatteryRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var automation = BatteryAutomationService.shared
    @State var rule: BatteryAutomationRule
    @State private var useLocation = false
    @State private var latitude = ""
    @State private var longitude = ""
    let save: (BatteryAutomationRule) -> Void

    private var candidate: BatteryAutomationRule {
        var value = rule
        value.latitude = useLocation ? Double(latitude) : nil
        value.longitude = useLocation ? Double(longitude) : nil
        return value
    }
    private var valid: Bool {
        candidate.isValid && !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!useLocation || (Double(latitude) != nil && Double(longitude) != nil))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("充电自动化规则").font(.title2.bold())
            Form {
                TextField("名称", text: $rule.name)
                Stepper("充电上限：\(rule.limit)%", value: $rule.limit, in: 50...100, step: 5)
                HStack {
                    Text("重复")
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Toggle(["日", "一", "二", "三", "四", "五", "六"][day - 1], isOn: Binding(
                            get: { rule.weekdays.contains(day) },
                            set: { value in if value { rule.weekdays.append(day) } else { rule.weekdays.removeAll { $0 == day } } }
                        )).toggleStyle(.button)
                    }
                }
                DatePicker("开始时间", selection: timeBinding(start: true), displayedComponents: .hourAndMinute)
                DatePicker("结束时间", selection: timeBinding(start: false), displayedComponents: .hourAndMinute)
                Text("开始与结束相同表示全天；跨午夜时段归属于开始的星期。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("仅在指定地点生效", isOn: $useLocation)
                if useLocation {
                    TextField("纬度（-90…90）", text: $latitude)
                    TextField("经度（-180…180）", text: $longitude)
                    Picker("地点半径", selection: $rule.radius) {
                        ForEach([100.0, 500, 1000, 3000, 10000], id: \.self) { radius in Text("\(Int(radius)) 米").tag(radius) }
                    }
                    HStack {
                        Button("获取当前位置 / 授权定位") { automation.requestLocation() }
                        Button("填入当前位置") {
                            if let location = automation.location {
                                latitude = String(location.latitude); longitude = String(location.longitude)
                            }
                        }.disabled(automation.location == nil)
                    }
                    Text(automation.locationMessage).font(.caption).foregroundStyle(.secondary)
                    Text("位置过期超过 5 分钟或定位精度不足时不匹配；坐标仅存储在本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(candidate); dismiss() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 570)
        .onAppear {
            useLocation = rule.latitude != nil
            latitude = rule.latitude.map(String.init(describing:)) ?? ""
            longitude = rule.longitude.map(String.init(describing:)) ?? ""
        }
    }
    private func timeBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            let minute = start ? rule.startMinute : rule.endMinute
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let value = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
            if start { rule.startMinute = value } else { rule.endMinute = value }
        })
    }
}
