// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct RadialSwitcherPresentationView: View {
    @ObservedObject private var service = RadialSwitcherService.shared
    @AppStorage(DefaultsKey.radialSwitcherPresentation) private var presentation = "ring"

    var body: some View {
        Group {
            if presentation == "columns", service.usesColumns { RadialSwitcherColumnsView() }
            else { RadialSwitcherView() }
        }
    }
}

struct RadialSwitcherColumnsView: View {
    @ObservedObject private var service = RadialSwitcherService.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                applicationList.frame(width: 220)
                Divider()
                windowList.frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 16) {
                Text(service.columnFocusOnChildren ? "松开 ⌘ 激活所选窗口" : "松开 ⌘ 激活 \(service.selectedApp?.localizedName ?? "应用")")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Tab 切换 · ` 切换栏 · Esc 取消")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 20)
            .frame(height: 48)
        }
        .frame(width: 680, height: 500)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.36), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 15, y: 7)
        .frame(width: 720, height: 560)
    }

    private var applicationList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("应用").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20).padding(.top, 20)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(service.columnApps, id: \.processIdentifier) { app in
                            let selected = service.selectedApp?.processIdentifier == app.processIdentifier
                            Button { service.activate(app) } label: {
                                HStack(spacing: 11) {
                                    appIcon(app.icon, size: 32)
                                    Text(app.localizedName ?? "App").font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).frame(height: 49)
                                .background(selected ? Color.accentColor.opacity(service.columnFocusOnChildren ? 0.07 : 0.19) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).focusable(false)
                            .id(app.processIdentifier)
                            .onHover { hovering in if hovering { service.hoverColumnApp(app) } }
                            .contextMenu {
                                Button("切换到应用") { service.activate(app) }
                                Button("新建窗口") { service.newWindow(app) }
                                Button("退出应用") { service.quit(app) }
                            }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }
                .onChange(of: service.selectedApp?.processIdentifier) { _, pid in
                    if let pid { proxy.scrollTo(pid, anchor: .center) }
                }
            }
        }
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                appIcon(service.selectedApp?.icon, size: 34)
                Text(service.selectedApp?.localizedName ?? "选择应用")
                    .font(.system(size: 19, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if service.supportsChildTabs {
                    Picker("显示内容", selection: Binding(
                        get: { service.childMode }, set: { service.switchChildMode($0) })) {
                        Text("窗口").tag("windows")
                        Text("标签页").tag("tabs")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 136)
                }
            }.padding(.horizontal, 20).padding(.top, 20)

            if let message = service.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(service.entries.enumerated()), id: \.element.id) { index, entry in
                            Button { service.select(index) } label: {
                                HStack(spacing: 12) {
                                    appIcon(entry.icon ?? service.selectedApp?.icon, size: 34)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(service.displayTitle(for: entry)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                        Text(detail(for: entry)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                .background(service.columnFocusOnChildren && service.highlightedIndex == index
                                    ? Color.accentColor.opacity(0.17) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).focusable(false)
                            .id(entry.id)
                            .onHover { hovering in if hovering { service.highlightColumnChild(index) } }
                            .contextMenu {
                                Button("关闭") { service.close(entry) }
                                Button("编辑名称与颜色") { service.editStyle(entry) }
                            }
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 16)
                }
                .onChange(of: service.highlightedIndex) { _, index in
                    guard service.columnFocusOnChildren, let index, service.entries.indices.contains(index) else { return }
                    proxy.scrollTo(service.entries[index].id, anchor: .center)
                }
            }
        }
    }

    private func appIcon(_ icon: NSImage?, size: CGFloat) -> some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "app").resizable().scaledToFit().padding(5) }
        }.frame(width: size, height: size)
    }

    private func detail(for entry: RadialSwitcherService.Entry) -> String {
        switch entry {
        case .window(let item):
            if item.isMinimized { return "已最小化" }
            if item.isAppHidden { return "应用已隐藏" }
            if item.isOnHiddenSpace { return "其他桌面" }
            return "窗口"
        case .tab: return "浏览器标签页"
        default: return ""
        }
    }
}
