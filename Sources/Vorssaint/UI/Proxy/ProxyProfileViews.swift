// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ProxyProfileEditor: View {
    @ObservedObject var service: ProxyService
    @State private var section = "YAML 草稿"
    @State private var rename = ""
    @State private var deleting = false
    @State private var showingDiff = false
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Button("导入 YAML…") { service.chooseFile() }.disabled(service.busy || service.state == .running)
                List(service.profiles) { profile in
                    Button { service.selectProfile(profile.id) } label: {
                        HStack { Text(profile.name).lineLimit(2); Spacer(); if profile.id == service.selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) } }
                    }.buttonStyle(.plain).disabled(service.busy)
                }
                HStack { Button("复制") { service.duplicateProfile() }; Button("删除", role: .destructive) { deleting = true }.disabled(service.state != .stopped) }.disabled(service.selectedID == nil || service.busy)
                TextField("配置名称", text: $rename)
                Button("重命名") { service.renameProfile(rename) }.disabled(rename.isEmpty || service.busy)
                Menu("导出…") { Button("当前配置（含覆写）") { service.exportProfile() }; Button("导入原件") { service.exportProfile(original: true) } }.disabled(service.selectedID == nil)
            }.padding(12).frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            VStack(alignment: .leading, spacing: 10) {
                Picker("内容", selection: $section) {
                    ForEach(["YAML 草稿", "覆写", "原件", "有效配置", "版本"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                if section == "版本" {
                    List(service.revisionHistory) { revision in
                        HStack {
                            VStack(alignment: .leading) { Text(revision.note); Text(revision.createdAt.formatted()).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Button("校验并回退") { service.rollback(revision) }.disabled(service.busy)
                        }
                    }
                } else if section == "原件" || section == "有效配置" {
                    ScrollView([.horizontal, .vertical]) { Text(section == "原件" ? service.originalText() : service.effectiveText()).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                } else {
                    TextEditor(text: section == "覆写" ? $service.editorOverrides : $service.editorYAML).font(.system(.body, design: .monospaced)).disabled(service.busy)
                    Text(section == "覆写" ? "YAML 映射深度合并；数组整体替换。运行管理字段由网络设置控制。" : "草稿可独立保存。应用前校验，失败保留正在运行的版本。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(service.editorDirty ? "有未保存修改" : "草稿已保存").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("放弃草稿") { service.discardDraft() }
                    Button("保存草稿") { service.saveDraft() }
                    Button("检查差异") { service.inspectDraft(); showingDiff = true }
                    Button("校验并应用") { service.applyDraft() }.buttonStyle(.borderedProminent)
                }.disabled(service.busy || service.selectedID == nil)
            }.padding(12).frame(minWidth: 470)
        }
        .onAppear { rename = service.selectedProfile?.name ?? "" }
        .onChange(of: service.selectedID) { _, _ in rename = service.selectedProfile?.name ?? "" }
        .confirmationDialog("删除当前配置及其草稿、版本和缓存？", isPresented: $deleting) { Button("删除配置", role: .destructive) { service.deleteSelectedProfile() } }
        .sheet(isPresented: $showingDiff) {
            VStack(alignment: .leading, spacing: 12) {
                Text("候选配置检查").font(.title2)
                if let error = service.error { Text(error).foregroundStyle(.red) }
                ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(service.draftReport) { Text($0.message).foregroundStyle($0.severity == .error ? .red : .secondary) }; Text(service.draftDiff).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("关闭") { showingDiff = false } }
            }.padding(24).frame(width: 720, height: 520)
        }
    }
}
struct ProxyRulesEditor: View {
    @ObservedObject var service: ProxyService
    @State private var query = ""
    @State private var editing = false
    @State private var index: Int?
    @State private var text = ""
    @State private var localError: String?
    var body: some View {
        let rules = service.draftRules
        VStack(alignment: .leading, spacing: 10) {
            HStack { TextField("搜索规则、域名或策略", text: $query); Button("添加规则") { index = nil; text = "DOMAIN,example.com,DIRECT"; editing = true } }
            Text("按草稿原顺序编辑；修改会将 YAML 转为 JSON 兼容格式，注释不保留，导入原件不变。需要在配置页应用后才会生效。覆写中的 rules 数组优先。")
                .font(.caption).foregroundStyle(.secondary)
            if let localError { Text(localError).foregroundStyle(.red) }
            List {
                ForEach(Array(rules.enumerated()).filter { query.isEmpty || $0.element.localizedCaseInsensitiveContains(query) }, id: \.offset) { row in
                    HStack {
                        Text("\(row.offset + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
                        Text(row.element).font(.system(.callout, design: .monospaced)).lineLimit(2)
                        Spacer()
                        Button("↑") { move(row.offset, -1) }.disabled(row.offset == 0)
                        Button("↓") { move(row.offset, 1) }.disabled(row.offset == rules.count - 1)
                        Button("编辑") { index = row.offset; text = row.element; editing = true }
                        Button("删除") { var rules = service.draftRules; rules.remove(at: row.offset); replace(rules) }
                    }
                }
            }
            HStack { Button("保存草稿") { service.saveDraft() }; Spacer(); Button("校验并应用") { service.applyDraft() }.buttonStyle(.borderedProminent) }
        }.padding().disabled(service.busy || service.selectedID == nil)
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(index == nil ? "添加规则" : "编辑规则").font(.title2)
                TextField("TYPE,内容,策略", text: $text).font(.system(.body, design: .monospaced))
                Text("支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、PROCESS-NAME、RULE-SET、GEOIP、MATCH。新规则插入第一条 MATCH 前。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("取消") { editing = false }; Button("写入草稿") {
                    var rules = service.draftRules
                    if let index, rules.indices.contains(index) { rules[index] = text } else { rules.insert(text, at: rules.firstIndex { $0.hasPrefix("MATCH,") } ?? rules.endIndex) }
                    replace(rules); editing = false
                }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(24).frame(width: 650)
        }
    }
    private func replace(_ rules: [String]) { do { try service.replaceRules(rules); localError = nil } catch { localError = error.localizedDescription } }
    private func move(_ index: Int, _ delta: Int) { var rules = service.draftRules; guard rules.indices.contains(index + delta) else { return }; rules.swapAt(index, index + delta); replace(rules) }
}
struct ProxyResourcesView: View {
    @ObservedObject var service: ProxyService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("规则集与远程资源").font(.headline); Spacer(); Button("刷新状态") { service.refreshResources() }; Button("更新全部规则集") { service.refreshResources(update: "*") } }.disabled(service.busy || service.state != .running)
            Text("更新由核心执行；失败保留已有缓存。本页不包含节点订阅。GEO 缓存在启动时检查完整性。")
                .font(.callout).foregroundStyle(.secondary)
            if service.state != .running { ContentUnavailableView("请先启动核心", systemImage: "externaldrive", description: Text("启动时会准备缺失资源；运行后可查看规则数量与更新时间。")) }
            List(service.resourceStates) { resource in
                HStack {
                    VStack(alignment: .leading) { Text(resource.name).font(.headline); Text("\(resource.behavior) · \(resource.count) 条规则"); Text(resource.updatedAt).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("更新") { service.refreshResources(update: resource.name) }.disabled(service.busy)
                }
            }
        }.padding().onAppear { service.refreshResources() }
    }
}
