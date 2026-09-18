// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Forms edit the same draft as the YAML editor. Unknown fields survive round-trips.
struct ProxyStructuredEditor: View {
    @ObservedObject var service: ProxyService
    @State private var section = "节点"
    @State private var presenting = false
    @State private var editIndex: Int?
    @State private var editName = ""
    @State private var previousProvider: String?
    @State private var object: [String: Any] = [:]
    @State private var localError: String?
    private var root: [String: Any] {
        guard !service.editorYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        return (try? ProxyConfigCompiler.document(Data(service.editorYAML.utf8))) ?? [:]
    }
    private var nodes: [[String: Any]] { root["proxies"] as? [[String: Any]] ?? [] }
    private var groups: [[String: Any]] { root["proxy-groups"] as? [[String: Any]] ?? [] }
    private var providers: [String: [String: Any]] { root["rule-providers"] as? [String: [String: Any]] ?? [:] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if service.selectedID == nil { Text("请先在配置页导入本地 YAML 文件。").foregroundStyle(.secondary) }
            Picker("图形编辑", selection: $section) { ForEach(["节点", "策略组", "DNS", "规则源"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            Text("修改写入同一份 YAML 草稿；保留其他字段，注释/排版会转为 JSON 兼容格式。重命名后请检查引用；校验并应用后才改变运行配置。")
                .font(.caption).foregroundStyle(.secondary)
            if let localError { Text(localError).foregroundStyle(.red) }
            if section == "DNS" {
                Button("编辑 DNS 配置") { object = root["dns"] as? [String: Any] ?? [:]; presenting = true }
                ScrollView { Text(json(root["dns"] ?? [:])).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else if section == "规则源" {
                List(providers.keys.sorted(), id: \.self) { name in
                    HStack { Text(name); Text(providers[name]?["behavior"] as? String ?? "").foregroundStyle(.secondary); Spacer(); Button("编辑") { editName = name; previousProvider = name; object = providers[name] ?? [:]; presenting = true }; Button("删除") { var next = providers; next.removeValue(forKey: name); write("rule-providers", next) } }
                }
                Button("添加规则源") { editName = ""; previousProvider = nil; object = ["type": "http", "behavior": "domain", "interval": 86400]; presenting = true }
            } else {
                let items = section == "节点" ? nodes : groups
                List(Array(items.enumerated()), id: \.offset) { row in
                    HStack { Text(row.element["name"] as? String ?? "未命名"); Text(row.element["type"] as? String ?? "").foregroundStyle(.secondary); Spacer(); Button("编辑") { editIndex = row.offset; object = row.element; presenting = true }; Button("删除") { var next = items; next.remove(at: row.offset); write(section == "节点" ? "proxies" : "proxy-groups", next) } }
                }
                Button(section == "节点" ? "添加节点" : "添加策略组") { editIndex = nil; object = section == "节点" ? ["type": "ss", "port": 443, "cipher": "aes-256-gcm"] : ["type": "select", "proxies": ["DIRECT"]]; presenting = true }
            }
            HStack { Button("保存草稿") { service.saveDraft() }; Spacer(); Button("校验并应用") { service.applyDraft() }.buttonStyle(.borderedProminent) }
        }.padding().disabled(service.busy || service.selectedID == nil)
        .sheet(isPresented: $presenting) {
            VStack(spacing: 12) {
                Text("编辑\(section)").font(.title2)
                Form {
                    if section == "节点" { nodeForm }
                    else if section == "策略组" { groupForm }
                    else if section == "DNS" { dnsForm }
                    else { providerForm }
                }.formStyle(.grouped)
                if let localError { Text(localError).foregroundStyle(.red).font(.caption) }
                HStack { Spacer(); Button("取消") { presenting = false }; Button("写入草稿") { localError = nil; save(); if localError == nil { presenting = false } }.buttonStyle(.borderedProminent) }
            }.padding(20).frame(width: 650, height: 610)
        }
    }
    private func string(_ key: String) -> Binding<String> { Binding(get: { object[key] as? String ?? "" }, set: { object[key] = $0 }) }
    private func number(_ key: String, fallback: Int) -> Binding<Int> { Binding(get: { object[key] as? Int ?? fallback }, set: { object[key] = $0 }) }
    private func bool(_ key: String, fallback: Bool = false) -> Binding<Bool> { Binding(get: { object[key] as? Bool ?? fallback }, set: { object[key] = $0 }) }
    private func lines(_ key: String) -> Binding<String> { Binding(get: { (object[key] as? [String] ?? []).joined(separator: "\n") }, set: { object[key] = $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }) }
    private func reality(_ key: String) -> Binding<String> { Binding(get: { (object["reality-opts"] as? [String: Any])?[key] as? String ?? "" }, set: { value in var options = object["reality-opts"] as? [String: Any] ?? [:]; options[key] = value; object["reality-opts"] = options }) }
    @ViewBuilder private var nodeForm: some View {
        TextField("名称", text: string("name"))
        Picker("协议", selection: string("type")) { Text("Shadowsocks").tag("ss"); Text("VLESS").tag("vless") }
        TextField("服务器", text: string("server"))
        TextField("端口", value: number("port", fallback: 443), format: .number.grouping(.never))
        Toggle("UDP", isOn: bool("udp"))
        if object["type"] as? String == "vless" {
            SecureField("UUID", text: string("uuid"))
            TextField("网络（如 tcp）", text: string("network"))
            TextField("Flow", text: string("flow"))
            Toggle("TLS", isOn: bool("tls", fallback: true))
            TextField("TLS Server Name", text: string("servername"))
            TextField("Reality Public Key", text: reality("public-key"))
            SecureField("Reality Short ID", text: reality("short-id"))
            TextField("Client Fingerprint", text: string("client-fingerprint"))
        } else {
            TextField("加密方法", text: string("cipher"))
            SecureField("密码", text: string("password"))
        }
    }
    @ViewBuilder private var groupForm: some View {
        TextField("名称", text: string("name"))
        Text("策略组类型：select")
        Text("成员（每行一个，支持节点、其他组、DIRECT、REJECT）")
        TextEditor(text: lines("proxies")).font(.system(.callout, design: .monospaced)).frame(height: 220)
        Text("可用名称：" + (nodes + groups).compactMap { $0["name"] as? String }.joined(separator: "、")).font(.caption)
    }
    @ViewBuilder private var dnsForm: some View {
        Toggle("启用 DNS", isOn: bool("enable"))
        Toggle("IPv6 解析", isOn: bool("ipv6"))
        Picker("模式", selection: string("enhanced-mode")) { Text("redir-host").tag("redir-host"); Text("fake-ip").tag("fake-ip") }
        Text("上游 DNS（每行一个）")
        TextEditor(text: lines("nameserver")).font(.system(.caption, design: .monospaced)).frame(height: 100)
        Text("Fallback（每行一个）")
        TextEditor(text: lines("fallback")).font(.system(.caption, design: .monospaced)).frame(height: 70)
        Text("公司 nameserver-policy、fallback-filter 等完整字段可在 YAML 草稿中编辑；此表单保持其原值。监听地址由网络设置管理。")
            .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var providerForm: some View {
        TextField("名称", text: $editName)
        TextField("HTTP(S) URL", text: string("url"))
        Picker("类型", selection: string("behavior")) { Text("domain").tag("domain"); Text("ipcidr").tag("ipcidr"); Text("classical").tag("classical") }
        TextField("更新间隔（秒）", value: number("interval", fallback: 86400), format: .number.grouping(.never))
        Text("缓存路径由应用隔离管理。改名后请修改 RULE-SET 引用。")
    }
    private func save() {
        switch section {
        case "DNS": write("dns", object)
        case "规则源": var next = providers; guard !editName.isEmpty else { localError = "规则源名称不能为空。"; return }; if previousProvider != editName { guard next[editName] == nil else { localError = "已有同名规则源。"; return }; if let previousProvider { next.removeValue(forKey: previousProvider) } }; next[editName] = object; write("rule-providers", next)
        default:
            if section == "节点", object["type"] as? String == "vless" { if object["tls"] == nil { object["tls"] = true }; if (object["network"] as? String ?? "").isEmpty { object["network"] = "tcp" } }
            let key = section == "节点" ? "proxies" : "proxy-groups"
            var next = section == "节点" ? nodes : groups
            if let editIndex, next.indices.contains(editIndex) { next[editIndex] = object } else { next.append(object) }
            write(key, next)
        }
    }
    private func write(_ key: String, _ value: Any) { do { try service.replaceSection(key, with: value); localError = nil } catch { localError = error.localizedDescription } }
    private func json(_ value: Any) -> String { (try? String(decoding: JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)) ?? "" }
}
