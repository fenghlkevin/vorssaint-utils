// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// A separate window survives dismissal of the menu-bar popover.
enum BatteryHelperSetupWindow {
    enum Action {
        case install, update, repair, reinstall
        var title: String {
            switch self {
            case .install: return "安装电池后台"
            case .update: return "更新电池后台"
            case .repair: return "修复电池后台"
            case .reinstall: return "重新安装充电控制助手"
            }
        }
    }
    private static var window: NSWindow?
    private static var currentAction: Action?
    static func close() { window?.close() }
    static func show(action: Action) {
        if let window, window.isVisible {
            let service = BatteryManagementService.shared
            if currentAction != action && !service.working && !service.performingUserAction && service.repairPhase == nil {
                currentAction = action
                window.title = action.title
                window.contentView = NSHostingView(rootView: BatteryHelperSetupView(action: action))
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = action.title
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: BatteryHelperSetupView(action: action))
        panel.center()
        window = panel
        currentAction = action
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct BatteryHelperSetupView: View {
    let action: BatteryHelperSetupWindow.Action
    @ObservedObject private var service = BatteryManagementService.shared
    @State private var started = false
    private var busy: Bool { service.working || service.performingUserAction || service.repairPhase != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(action.title, systemImage: "battery.100percent")
                .font(.title2.bold())
            ScrollView {
              VStack(alignment: .leading, spacing: 14) {
            if action == .reinstall {
                Text("使用当前 App 内嵌的助手重新安装，即使版本相同也可以执行。保留充电上限、自动化规则和日志。")
                Text("流程：确认释放充电控制 → 注销旧助手 → 注册当前助手 → 验证连接与版本。恢复未确认时会中止；需要管理员修复时会另行征求确认。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Helper 是随 Vorssaint 安装的电池控制后台，需要系统授权，才能执行充电管理。它不是另一个电池管理 App。")
            Text("系统可能要求管理员密码，或要求在“登录项与扩展”中允许后台运行。请在系统弹窗中操作，不要把密码发给任何人。")
                .foregroundStyle(.secondary)
            if action != .install {
                Text("更新或修复前会检查旧后台的控制与恢复记录。无法确认安全时会停止操作，不会强行删除恢复记录。")
                    .foregroundStyle(.secondary)
            }
            Divider()
            if started {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(service.repairPhase ?? service.diagnosisTitle).fontWeight(.semibold)
                }
                Text("授权：\(service.permissionSummary)  ·  连接：\(service.connectionSummary)  ·  版本：\(service.versionSummary)")
                    .font(.callout)
                Text(service.diagnosisDescription).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = service.lastError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("注册成功 ≠ 已连接 ≠ 充电控制已生效。完成后将分别检查授权、连接、版本和充电接口兼容性。")
                    .font(.callout)
            }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("关闭此窗口不会撤销已开始的系统操作。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !started {
                    Button("暂不操作") { BatteryHelperSetupWindow.close() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(started ? (service.connectionSummary == "已连接" && service.lastError == nil ? "检查状态" : "重试 / 继续授权")
                       : action == .reinstall ? "确认重新安装" : "继续并请求系统授权") {
                    if started && service.connectionSummary == "已连接" && service.lastError == nil { service.checkAndRepair() }
                    else {
                        started = true
                        switch action {
                        case .install: service.authorize(confirmed: true)
                        case .update: service.replaceBackend(confirmed: true)
                        case .repair: service.repairWithAdministratorApproval(confirmed: true)
                        case .reinstall: service.reinstallBackend(confirmed: true)
                        }
                    }
                }.buttonStyle(.borderedProminent).disabled(busy)
            }
            if started && service.offersPrivilegedRepair {
                Button("改用管理员安全修复…") { service.repairWithAdministratorApproval() }
                    .disabled(busy)
            }
        }.padding(24).frame(width: 580, height: 560)
    }
}
