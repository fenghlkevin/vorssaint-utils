// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct RadialSwitcherView: View {
    @ObservedObject private var service = RadialSwitcherService.shared

    var body: some View {
        ZStack {
            // A translucent annulus keeps the desktop visible through the hub.
            Circle()
                .stroke(.ultraThinMaterial, lineWidth: 132)
                .frame(width: RadialSwitcherLayout.wheelDiameter - 132,
                       height: RadialSwitcherLayout.wheelDiameter - 132)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                .frame(width: RadialSwitcherLayout.wheelDiameter, height: RadialSwitcherLayout.wheelDiameter)
            Circle()
                .fill(.ultraThinMaterial.opacity(0.65))
                .overlay(Circle().strokeBorder(.white.opacity(0.24), lineWidth: 0.75))
                .frame(width: 208, height: 208)

            ForEach(Array(service.entries.enumerated()), id: \.element.id) { index, entry in
                let unit = RadialMenuGeometry.unitPosition(index: index, itemCount: service.entries.count)
                let width = max(CGFloat(38), min(CGFloat(88),
                    RadialSwitcherLayout.ringRadius * 2 * .pi / CGFloat(max(service.entries.count, 1)) * 0.88))
                Button { service.select(index) } label: {
                    VStack(spacing: 7) {
                        entryIcon(entry, size: min(58, width - 12))
                            .padding(6)
                            .background(service.highlightedIndex == index
                                ? Color.accentColor.opacity(0.16)
                                : service.color(for: entry)?.opacity(0.16) ?? .clear,
                                in: RoundedRectangle(cornerRadius: 17))
                            .overlay(RoundedRectangle(cornerRadius: 17)
                                .strokeBorder(service.highlightedIndex == index
                                    ? Color.accentColor.opacity(0.58) : .clear, lineWidth: 1))
                            .shadow(color: service.highlightedIndex == index
                                ? Color.accentColor.opacity(0.12) : .clear, radius: 5, y: 2)
                        Text(service.displayTitle(for: entry))
                            .font(.system(size: width < 50 ? 9 : 11, weight: .medium))
                            .lineLimit(1)
                            .frame(width: width)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .simultaneousGesture(DragGesture(minimumDistance: 6).onEnded { value in
                    service.quitIfDragged(entry, distance: hypot(value.translation.width, value.translation.height))
                })
                .contextMenu {
                    switch entry {
                    case .app(let app):
                        Button("切换到应用") { service.activate(app) }
                        Button("展开窗口或标签") { service.showChildren(for: app) }
                        Button("新建窗口") { service.newWindow(app) }
                        Button("退出应用") { service.quit(app) }
                    case .window, .tab:
                        Button("关闭") { service.close(entry) }
                        Button("编辑名称与颜色") { service.editStyle(entry) }
                    default: EmptyView()
                    }
                }
                .offset(x: unit.dx * RadialSwitcherLayout.ringRadius,
                        y: -unit.dyUp * RadialSwitcherLayout.ringRadius)
                .accessibilityLabel(entry.title)
            }

            centerContent
                .frame(width: 172, height: 190)

            Text(service.showingWindows ? "点击切换 · 松开 ⌘ 确认 · Esc 取消" : "松开 ⌘ 切换应用 · ` 展开窗口")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .offset(y: RadialSwitcherLayout.wheelDiameter / 2 + 25)
        }
        .frame(width: RadialSwitcherLayout.panelSize, height: RadialSwitcherLayout.panelSize)
    }

    private var centerContent: some View {
        VStack(spacing: 9) {
            if service.showingWindows, let icon = service.centerApp?.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 32, height: 32)
            }
            Text(service.centerApp?.localizedName ?? service.heading)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .onTapGesture(count: 2) { service.toggleFavoritesPinned() }
            if let message = service.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
            } else {
                Text(service.showingWindows
                    ? "\(service.childItemCount) 个\(service.childMode == "tabs" ? "标签页" : "窗口")"
                    : "点击图标，直接切换")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if service.supportsChildTabs {
                Picker("显示内容", selection: Binding(
                    get: { service.childMode }, set: { service.switchChildMode($0) })) {
                    Text("窗口").tag("windows")
                    Text("标签页").tag("tabs")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 152)
            }
            Button { service.centerAction() } label: {
                Label(service.showingWindows ? "返回应用" : "展开窗口", systemImage: "square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(service.centerApp == nil)
            if service.currentPage > 0 {
                Text("第 \(service.currentPage + 1) 页").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private func entryIcon(_ entry: RadialSwitcherService.Entry, size: CGFloat) -> some View {
        Group {
            if let icon = entry.icon { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: entry.symbol).resizable().scaledToFit().padding(10) }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.13), radius: 3, y: 2)
    }
}

struct RadialSwitcherPreviewView: View {
    @ObservedObject private var service = RadialSwitcherService.shared

    var body: some View {
        VStack(spacing: 10) {
            Text(service.previewTitle)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let image = service.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(width: 420, height: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
