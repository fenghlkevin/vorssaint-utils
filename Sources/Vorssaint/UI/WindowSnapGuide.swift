// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Shared visual vocabulary for setup and the menu panel.
struct WindowLayoutGlyph: View {
    let action: WindowLayoutAction

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let rect = WindowLayoutGeometry.rect(for: action, current: bounds.insetBy(dx: 5, dy: 4),
                                                  visibleFrame: bounds)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: max(1, rect.width - 3), height: max(1, rect.height - 3))
                    .offset(x: rect.minX + 1.5, y: bounds.height - rect.maxY + 1.5)
            }
        }
        .frame(width: 32, height: 22)
        .accessibilityHidden(true)
    }
}

struct WindowSnapCopy {
    let language: AppLanguage
    private var chinese: Bool { [.zhHans, .zhTW, .zhHK].contains(language) }
    func choose(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    var activation: String { choose("悬浮分屏岛", "Snap island") }
    var title: String { choose("拖到分屏岛，松手排列", "Drag to the island. Release to arrange.") }
    var caption: String { choose("拖动标题栏，屏幕上方会出现分屏岛。靠近展开，拖入布局小格，看到预览后松手。移开或按 Esc 取消，拖离已排列窗口恢复大小。", "Drag a title bar to reveal the island above. Approach to expand, drag into a layout cell, then release to snap. Move away or press Esc to cancel. Pull a tiled window free to restore its size.") }
    var advanced: String { choose("更多布局与操作", "More layouts and actions") }
    var enabled: String { choose("分屏岛已就绪", "Snap island are ready") }
    var disabled: String { choose("开启后，直接拖动窗口即可排列", "Enable to arrange windows by dragging") }
    var freeDrag: String { choose("可选：按住按键自由拖动", "Optional: modifier-key dragging") }
}

struct WindowSnapGuide: View {
    @ObservedObject private var l10n = L10n.shared
    var compact = false
    private var copy: WindowSnapCopy { WindowSnapCopy(language: l10n.language) }
    private var text: WindowLayoutFeatureStrings { FeatureStrings.windowLayout(l10n.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.title).font(.headline)
            HStack(spacing: 0) {
                example(.leftHalf, copy.choose("二分屏", "Halves"))
                Spacer(minLength: 4)
                example(.leftThird, copy.choose("三分屏", "Thirds"))
                Spacer(minLength: 4)
                example(.topLeft, copy.choose("四分屏", "Quarters"))
            }
            Text(copy.caption).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func example(_ action: WindowLayoutAction, _ label: String) -> some View {
        VStack(spacing: 5) {
            WindowLayoutGlyph(action: action)
            Text(label).font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
        }
    }
}
