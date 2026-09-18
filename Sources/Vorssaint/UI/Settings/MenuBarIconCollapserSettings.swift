// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Dedicated settings surface for the installable menu bar organization
/// feature. Feature Hub owns whether this page exists; the toggle here owns
/// whether its divider is currently present.
struct MenuBarIconCollapserSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var collapser = MenuBarIconCollapser.shared

    private var strings: MenuBarIconCollapserStrings {
        .strings(for: l10n.language)
    }

    var body: some View {
        Form {
            Section {
                Toggle(strings.enable, isOn: Binding(
                    get: { collapser.isEnabled },
                    set: { collapser.setEnabled($0) }
                ))
                Text(strings.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if collapser.isEnabled {
                Section(MenuBarShelfStrings.text("展开方式", "Reveal style")) {
                    HStack(spacing: 12) {
                        modeCard(.menuBar,
                            title: MenuBarShelfStrings.text("菜单栏展开", "In the menu bar"),
                            caption: MenuBarShelfStrings.text("现有方式 · 在原位置显示图标", "Original mode · reveal icons in place"))
                        modeCard(.shelf,
                            title: MenuBarShelfStrings.text("独立图标面板", "Separate icon panel"),
                            caption: MenuBarShelfStrings.text("在菜单栏下方集中显示", "Show icons below the menu bar"))
                            .disabled(!collapser.usesNativeVisibility)
                    }
                    if !collapser.usesNativeVisibility {
                        Text(MenuBarShelfStrings.text("独立面板目前支持 macOS 27。", "The separate panel currently requires macOS 27."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section(collapser.revealMode == .shelf
                        ? MenuBarShelfStrings.text("面板行为", "Panel behavior") : strings.configuration) {
                    if collapser.revealMode == .shelf {
                        Toggle(MenuBarShelfStrings.text("鼠标悬停时展开", "Open on hover"), isOn: Binding(
                            get: { collapser.expandOnHover }, set: { collapser.setExpandOnHover($0) }))
                        Text(MenuBarShelfStrings.text("在双箭头上停留片刻后打开面板。", "Pause over the chevrons to open the panel."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker(collapser.revealMode == .shelf
                           ? MenuBarShelfStrings.text("鼠标离开后收起", "Close after pointer leaves") : strings.automaticCollapse, selection: Binding(
                        get: { collapser.autoCollapseDelay },
                        set: { collapser.setAutoCollapseDelay($0) }
                    )) {
                        ForEach(MenuBarIconCollapserSupport.allowedDelays, id: \.self) { seconds in
                            Text(strings.delayTitle(seconds)).tag(seconds)
                        }
                    }
                    if collapser.revealMode == .shelf {
                        LabeledContent(MenuBarShelfStrings.text("显示位置", "Position"),
                            value: MenuBarShelfStrings.text("双箭头下方 · 自动避让屏幕边缘", "Below chevrons · constrained to screen"))
                        Toggle(MenuBarShelfStrings.text("悬停时显示图标名称", "Show names on hover"), isOn: Binding(
                            get: { collapser.showShelfNames }, set: { collapser.setShowShelfNames($0) }))
                        Text(MenuBarShelfStrings.text("面板内操作时暂停收起；点击图钉可临时固定，Esc 关闭。", "Auto-close pauses inside the panel. Pin temporarily, or press Esc to close."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(collapser.revealMode == .shelf
                               ? MenuBarShelfStrings.text("预览面板", "Preview panel")
                               : (collapser.isCollapsed ? strings.expand : strings.collapse)) {
                            collapser.toggle()
                        }
                        Button(strings.checkPosition) {
                            collapser.refreshPlacement()
                        }
                    }
                    if collapser.isTransitioning {
                        ProgressView().controlSize(.small)
                    }
                    if let error = collapser.operationError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    } else if collapser.placementError {
                        Text(strings.placementError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if collapser.placementIsSafe {
                        Text(strings.placementReady)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section(MenuBarShelfStrings.text("图标范围", "Managed icons")) {
                    MenuBarModeDiagram(mode: .menuBar)
                    Text(strings.instruction).fixedSize(horizontal: false, vertical: true)
                    if collapser.revealMode == .shelf {
                        Text(MenuBarShelfStrings.text(
                            "面板使用应用原始图标，不截取屏幕。点击会临时恢复原图标并打开真实菜单，结束操作后重新隐藏。",
                            "The panel uses original app artwork, without capturing the screen. Selecting an icon temporarily reveals its original control and opens its real menu, then hides it after interaction."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if collapser.usesNativeVisibility {
                    Text(MenuBarIconCollapserStrings.nativeNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(strings.interactionHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(strings.title)
        .onAppear { collapser.refreshPlacement() }
    }

    private func modeCard(_ mode: MenuBarRevealMode, title: String, caption: String) -> some View {
        let selected = collapser.revealMode == mode
        return Button { collapser.setRevealMode(mode) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(title).font(.headline)
                }
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(height: 30, alignment: .top)
                MenuBarModeDiagram(mode: mode)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.04) : Color.primary.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? MenuBarShelfStrings.text("已选择", "Selected") : "")
    }
}

private struct MenuBarModeDiagram: View {
    let mode: MenuBarRevealMode
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 9) {
                if mode == .menuBar {
                    Image(systemName: "doc.on.clipboard")
                    Image(systemName: "cloud")
                    Image(systemName: "terminal")
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right.2")
                Image(systemName: "infinity").foregroundStyle(Color.accentColor)
                Image(systemName: "battery.100percent")
                Image(systemName: "wifi")
            }.padding(8).background(.quaternary, in: Capsule())
            if mode == .shelf {
                HStack(spacing: 14) {
                    Image(systemName: "doc.on.clipboard")
                    Image(systemName: "cloud")
                    Image(systemName: "terminal")
                    Divider().frame(height: 12)
                    Image(systemName: "pin")
                }.padding(8).background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            } else {
                Color.clear.frame(height: 29)
            }
        }.font(.system(size: 12)).frame(height: 70)
            .accessibilityHidden(true)
    }
}
