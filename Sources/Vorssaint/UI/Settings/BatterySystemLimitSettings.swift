// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Keep target, consent and progress together; capabilities are information,
/// not an orange warning that looks like a connection failure.
struct BatterySystemLimitSettings: View {
    @ObservedObject private var service = BatteryManagementService.shared
    @State private var confirming = false

    private var enabled: Bool { service.isEnabled && service.systemLimitConsent }
    private var status: String {
        if let error = service.lastError { return error }
        if !service.isEnabled { return "电池管理已关闭；开启后可启用充电上限。" }
        if !service.systemLimitConsent {
            return "尚未启用。已选择 \(service.chargeLimit)%；打开右侧开关并确认后应用。"
        }
        if service.systemLimitReadback != service.effectiveLimit {
            return "正在等待系统确认 \(service.effectiveLimit)% 上限。"
        }
        if service.systemPolicyLimit == service.effectiveLimit {
            return "系统已确认 \(service.effectiveLimit)% 限充策略。"
        }
        return "上限设置已回读为 \(service.effectiveLimit)%；系统执行状态尚待确认。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("充电上限").font(.headline)
                Spacer()
                Picker("充电上限百分比", selection: $service.chargeLimit) {
                    if !service.systemChargeLimits.contains(service.chargeLimit) {
                        Text("\(service.chargeLimit)%（不支持）").tag(service.chargeLimit).disabled(true)
                    }
                    ForEach(service.systemChargeLimits, id: \.self) { limit in
                        Text("\(limit)%").tag(limit)
                    }
                }
                .labelsHidden().frame(width: 150)
                .disabled(service.performingUserAction || service.repairPhase != nil)
                Toggle("启用充电上限", isOn: Binding(
                    get: { service.systemLimitConsent },
                    set: { if $0 { confirming = true } else { service.setSystemLimitConsent(false) } }))
                    .labelsHidden()
                    .disabled(!service.isEnabled || service.performingUserAction || service.repairPhase != nil
                              || (!service.systemLimitConsent && !service.systemChargeLimits.contains(service.chargeLimit)))
                    .help("确认后将所选百分比应用到 macOS 系统充电上限")
            }
            Label(status, systemImage: service.lastError != nil
                  ? "exclamationmark.triangle" : enabled ? "info.circle" : "power")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let rule = service.activeRule, enabled {
                Text("自动化规则“\(rule)”当前使用 \(service.effectiveLimit)%；上方选择的是基础上限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("此模式支持什么？") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("支持设置系统报告的充电上限。不支持立即停充、主动放电和自定义温度阈值；温控及睡眠行为由 macOS 决定。")
                    Text("电量已超过上限时，不会主动放电到目标百分比。系统策略确认也不代表电池已发生停充切换。")
                    Text("若系统执行状态一直未确认，可打开系统电池设置检查。关闭此功能会尝试恢复接管前的系统上限。")
                }.font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("检查限充状态") { service.checkAndRepair() }
                    .disabled(service.working || service.repairPhase != nil)
                Button("打开系统电池设置…") { service.openSystemBatterySettings() }
            }
        }
        .padding(.vertical, 8)
        .alert("启用 \(service.chargeLimit)% 充电上限？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("启用充电上限") { service.setSystemLimitConsent(true) }
        } message: {
            Text("将所选上限交给 macOS 执行；如有启用的自动化规则，则优先使用规则上限。请先退出 BatFi 等其他充电工具。关闭管理或后台断连时会尝试恢复之前的系统上限。")
        }
    }
}
