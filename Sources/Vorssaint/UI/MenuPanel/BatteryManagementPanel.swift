// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Charts
import SwiftUI

struct BatteryManagementPanel: View {
    @ObservedObject private var model = BatteryPanelModel.shared
    @ObservedObject private var service = BatteryManagementService.shared
    @AppStorage(DefaultsKey.batteryMenuHiddenFields) private var hidden = ""
    var viewport = CGSize(width: 320, height: 820)
    @State private var contentHeight: CGFloat = 820
    var presentationID = UUID()
    let openSettings: () -> Void
    var contentHeightChanged: (CGFloat) -> Void = { _ in }

    var body: some View {
        let scale = BatteryPanelLayout.contentScale(contentHeight: contentHeight,
                                                    viewportHeight: viewport.height)
        let displayedHeight = min(viewport.height, ceil(contentHeight * scale))
        return VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("电池", systemImage: "battery.100percent").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(model.reading.chargePercent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 16, weight: .bold)).monospacedDigit()
                }
                VStack(spacing: 4) {
                    row("本次开机时间", duration(ProcessInfo.processInfo.systemUptime))
                    row("电池状态", model.stateText)
                    row("应用模式", modeText)
                    if let remaining = model.reading.timeRemainingSeconds {
                        row("预计可用时间", duration(remaining))
                    }
                }
                Divider()
                VStack(spacing: 4) {
                    if shows(.source) { row("电源", model.reading.hasBattery ? (model.reading.externalConnected ? "电源适配器" : "电池") : "—") }
                    if shows(.cycles) { row("循环计数", model.reading.cycleCount.map(String.init) ?? "—") }
                    if shows(.temperature) { row("温度", model.temperature.map { String(format: "%.1f°C", $0) } ?? "—").help(model.temperatureHelp) }
                    if shows(.health) { row("电池健康（最大容量）", model.reading.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—") }
                    if shows(.lastDischarge) { row("上次开始放电", relative(model.lastDischarge)) }
                    if shows(.lastFullCharge) { row("上次完全充电", relative(model.lastFullCharge)) }
                }
                if shows(.history) { Divider(); history }
                if shows(.power) { Divider(); power }
                if shows(.apps) { Divider(); energyApps }
                Divider()
                VStack(spacing: 2) {
                    action("充电至 100%", icon: "bolt.fill") { service.forceCharge() }
                    action("停止充电", icon: "pause.fill") { service.inhibitCharging() }
                    action("恢复自动充电", icon: "arrow.clockwise") { service.restoreAutomatic() }
                    action("使用电池运行至 \(service.effectiveLimit)%", icon: "battery.50percent") { service.forceDischarge() }
                        .disabled(!service.dischargeSupported)
                }
                .disabled(!service.backendReady || service.performingUserAction)
                BatteryTakeoverButton()
                if !service.backendReady {
                    Button("授权电池后台…") { service.authorize() }
                    Text(service.accessText).font(.caption).foregroundStyle(.secondary)
                }
                if let rule = service.activeRule { row("自动化规则", rule) }
                if let warning = service.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if let error = service.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("电池设置…", action: openSettings)
                }
                Text("时间仅记录观测到的事件；— 表示暂无数据。")
                    .font(.caption2).foregroundStyle(.tertiary)
        }.font(.system(size: 11))
            .controlSize(.small)
            .padding(12)
            .frame(width: viewport.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { content in
                Color.clear.preference(key: BatteryPanelHeightKey.self, value: content.size.height)
            })
            .scaleEffect(scale, anchor: .top)
            .frame(width: viewport.width, height: displayedHeight, alignment: .top)
        .onPreferenceChange(BatteryPanelHeightKey.self) { height in
            contentHeight = height
            let scale = BatteryPanelLayout.contentScale(contentHeight: height,
                                                        viewportHeight: viewport.height)
            contentHeightChanged(min(viewport.height, ceil(height * scale)))
        }
        .id(presentationID)
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
        .onChange(of: hidden) { _, _ in model.sample() }
    }

    private func shows(_ field: BatteryMenuField) -> Bool { field.isVisible(hidden: hidden) }

    private var modeText: String {
        service.statusText
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.system(size: 11))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("过去 12 小时").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(model.history.enumerated()), id: \.element.id) { index, point in
                    if point.pluggedIn {
                        RectangleMark(xStart: .value("开始", point.date),
                                      xEnd: .value("结束", min(point.date.addingTimeInterval(60), model.observedAt)),
                                      yStart: .value("最低", 0), yEnd: .value("最高", 100))
                            .foregroundStyle(.orange.opacity(0.12))
                    }
                    PointMark(x: .value("时间", point.date), y: .value("电量", point.percent))
                        .symbolSize(8).foregroundStyle(.green)
                    if index > 0, point.date.timeIntervalSince(model.history[index - 1].date) < 120 {
                        let previous = model.history[index - 1]
                        LineMark(x: .value("时间", previous.date), y: .value("电量", previous.percent),
                                 series: .value("区间", index)).foregroundStyle(.green)
                        LineMark(x: .value("时间", point.date), y: .value("电量", point.percent),
                                 series: .value("区间", index)).foregroundStyle(.green)
                    }
                }
            }
            .chartXScale(domain: model.observedAt.addingTimeInterval(-43200)...model.observedAt)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute())
            } }
            .frame(height: 84)
            Text(model.history.count < 2 ? "正在积累历史数据…" : "绿色：电量 · 浅橙色：接通电源 · 空白：未采样")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var power: some View {
        let r = model.reading
        let flow = BatteryPowerFlow(external: r.externalConnected, hasBattery: r.hasBattery,
                                    charging: r.isCharging, adapter: r.adapterWatts,
                                    battery: r.batteryWatts, system: r.systemWatts,
                                    forcedDischarge: service.mode == .discharging)
        return VStack(alignment: .leading, spacing: 8) {
            Text("功率分配").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                VStack(spacing: 4) { ForEach(flow.inputs) { powerBadge($0) } }
                Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(.secondary)
                VStack(spacing: 4) { ForEach(flow.outputs) { powerBadge($0) } }
            }
            .help("左侧为输入，右侧为输出。电脑功率按实时输入和电池流向配平；系统总功率仅在主要输入缺失时回退。适配器额定功率：\(watts(r.adapterMaxWatts))，不参与实时流量计算。")
            if let note = flow.note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }

    private func powerBadge(_ node: BatteryPowerFlow.Node) -> some View {
        HStack(spacing: 7) {
            Image(systemName: node.symbol).font(.system(size: 16))
            Text(watts(node.watts)).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(node.title) \(watts(node.watts))")
            .help(node.title)
    }

    private var energyApps: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("高能耗应用").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if model.appsLoading { ProgressView().controlSize(.mini) }
            }
            ForEach(model.apps) { app in
                HStack {
                    if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f", app.value)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.system(size: 11))
            }
            if model.apps.isEmpty && !model.appsLoading {
                Text("暂无活跃应用数据").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { HStack { Label(title, systemImage: icon); Spacer() }.contentShape(Rectangle()) }
            .buttonStyle(.plain).padding(.vertical, 2).disabled(!model.reading.hasBattery)
    }
    private func watts(_ value: Double?) -> String { value.map { String(format: "%.1f W", $0) } ?? "—" }
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
    private func relative(_ date: Date?) -> String {
        guard let date else { return "尚未记录" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: model.observedAt)
    }
}

private struct BatteryPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
