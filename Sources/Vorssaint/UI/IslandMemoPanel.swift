// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Layout reference: Atoll NotchNotesView (GPL-3.0-or-later).
// https://github.com/Ebullioscopic/Atoll

import AppKit
import SwiftUI

private let memoColors: [Color] = [.yellow, .orange, .red, .green, .blue, .purple]
private let memoColorNames = ["黄色", "橙色", "红色", "绿色", "蓝色", "紫色"]

struct IslandMemoPanel: View {
    @ObservedObject var service: IslandMemoService
    @State private var editing: IslandMemo?
    @State private var search = ""
    @State private var showingSearch = false
    @State private var colorFilter: Int?
    @State private var confirmClear = false
    @State private var clipboardEmpty = false

    private var filtered: [IslandMemo] {
        service.orderedMemos.filter { memo in
            (search.isEmpty || memo.displayTitle.localizedCaseInsensitiveContains(search) || memo.text.localizedCaseInsensitiveContains(search))
                && (colorFilter == nil || (memo.colorIndex ?? 0) == colorFilter)
        }
    }

    var body: some View {
        Group {
            if let memo = editing {
                IslandMemoEditor(memo: memo, save: { service.save($0) }, close: { editing = nil })
                    .id(memo.id)
            } else { list }
        }
        .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white).buttonStyle(.plain)
        .alert("删除全部备忘录？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) { service.deleteAll() }
        } message: { Text("删除后可在本次使用中点击“撤销删除”恢复。") }
        .alert("剪贴板中没有文本", isPresented: $clipboardEmpty) { Button("好", role: .cancel) {} }
    }

    private var list: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Text("备忘录").font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("\(service.memos.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                tool("magnifyingglass", label: "搜索与颜色筛选", tint: showingSearch ? .yellow : .white) {
                    showingSearch.toggle()
                    if !showingSearch { search = ""; colorFilter = nil }
                }
                tool("doc.on.clipboard", label: "从剪贴板新建") {
                    guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { clipboardEmpty = true; return }
                    create(text: text)
                }
                if !service.memos.isEmpty { tool("trash", label: "删除全部", tint: .red) { confirmClear = true } }
                tool("plus", label: "新建备忘录") { create() }
            }
            if showingSearch {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
                    TextField("搜索备忘录…", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                    Button { colorFilter = nil } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(colorFilter == nil ? .white : .gray)
                    }.help("全部颜色").accessibilityLabel("全部颜色")
                    ForEach(memoColors.indices, id: \.self) { index in
                        colorButton(index, selected: colorFilter == index) { colorFilter = colorFilter == index ? nil : index }
                    }
                }.padding(8).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: service.memos.isEmpty ? "note.text" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.yellow.opacity(0.6))
                    Text(service.memos.isEmpty ? "随手记下你的想法" : "没有匹配的备忘录").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    if service.memos.isEmpty { Button("新建备忘录") { create() }.font(.system(size: 12)).foregroundStyle(.yellow) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { memo in
                            IslandMemoCard(memo: memo, select: { editing = memo }, pin: { service.togglePinned(memo.id) },
                                           complete: { service.toggleCompleted(memo.id) }, delete: { service.delete(memo.id) })
                        }
                    }.padding(1)
                }.scrollIndicators(.hidden)
            }
            if !service.deletedMemos.isEmpty {
                HStack {
                    Text("已删除 \(service.deletedMemos.count) 条").foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button("撤销删除") { service.undoDelete() }.foregroundStyle(.yellow)
                }.font(.system(size: 10))
            }
        }
    }

    private func create(text: String = "") {
        editing = IslandMemo(id: UUID(), text: text, createdAt: Date(), completed: false, pinned: false)
    }

    private func tool(_ symbol: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint.opacity(0.8))
                .frame(width: 27, height: 27).background(.white.opacity(0.09), in: Circle())
        }.help(label).accessibilityLabel(label)
    }
}

private struct IslandMemoCard: View {
    let memo: IslandMemo
    let select: () -> Void
    let pin: () -> Void
    let complete: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var copied = false
    private var color: Color { memoColors[min(max(memo.colorIndex ?? 0, 0), memoColors.count - 1)] }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            if memo.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(color) }
                            Text(memo.displayTitle).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).strikethrough(memo.completed)
                        }
                        Text(memo.text.isEmpty ? "无正文" : memo.text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.accessibilityLabel("编辑：\(memo.displayTitle)")
            Group {
                if hovering {
                    HStack(spacing: 3) {
                        action(memo.pinned ? "pin.fill" : "pin", label: "置顶", perform: pin)
                        action(copied ? "checkmark" : "doc.on.doc", label: "复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(memo.text.isEmpty ? memo.displayTitle : memo.text, forType: .string)
                            copied = true
                        }
                        action("trash", label: "删除", perform: delete)
                    }
                } else {
                    Text(memo.modificationDate, style: .relative).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
            }.frame(width: 88, alignment: .trailing)
        }
        .padding(11).frame(height: 74)
        .background(.white.opacity(hovering ? 0.1 : 0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.18)))
        .onHover { hovering = $0; if !$0 { copied = false } }
        .contextMenu {
            Button("编辑", action: select)
            Button(memo.pinned ? "取消置顶" : "置顶", action: pin)
            Button(memo.completed ? "标记未完成" : "标记已完成", action: complete)
            Button("删除", role: .destructive, action: delete)
        }
    }

    private func action(_ symbol: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).font(.system(size: 10)).frame(width: 26, height: 26).background(.white.opacity(0.09), in: Circle()) }
            .accessibilityLabel(label).help(label)
    }
}

struct IslandMemoEditor: View {
    @State var memo: IslandMemo
    let save: (IslandMemo) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { save(memo); close() } label: { Label("备忘录", systemImage: "chevron.left") }
                Spacer()
                Text("自动保存").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                Button("完成") { save(memo); close() }.foregroundStyle(.yellow).fontWeight(.semibold)
            }.font(.system(size: 13, weight: .medium))
            HStack(spacing: 8) {
                TextField("标题", text: Binding(get: { memo.title ?? "" }, set: { memo.title = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 17, weight: .bold, design: .rounded))
                ForEach(memoColors.indices, id: \.self) { index in
                    colorButton(index, selected: (memo.colorIndex ?? 0) == index) { memo.colorIndex = index }
                }
            }.padding(.vertical, 4)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $memo.text).font(.system(size: 13)).lineSpacing(4)
                    .scrollContentBackground(.hidden).padding(6)
                if memo.text.isEmpty { Text("开始记录…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.3)).padding(11).allowsHitTesting(false) }
            }.background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            HStack { Spacer(); Text("\(memo.text.count) 字").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.35)) }
        }
        .onChange(of: memo) { _, note in save(note) }
        .onDisappear { save(memo) }
    }
}

private func colorButton(_ index: Int, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Circle().fill(memoColors[index]).frame(width: 12, height: 12)
            .padding(3).overlay(Circle().stroke(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
    }.help(memoColorNames[index]).accessibilityLabel(memoColorNames[index]).accessibilityAddTraits(selected ? .isSelected : [])
}
