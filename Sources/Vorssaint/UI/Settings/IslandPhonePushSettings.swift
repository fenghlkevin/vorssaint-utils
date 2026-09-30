import AppKit
import SwiftUI

struct IslandPhonePushSettings: View {
    @ObservedObject private var push = IslandPhonePushService.shared
    @State private var secrets = IslandPhonePushSecrets()
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通知 · iPhone").font(.headline)
            VStack(alignment: .leading, spacing: 14) {
                Toggle("通知我的 iPhone", isOn: $push.configuration.enabled)
                Text("通过 Bark 接收 Codex 审批、提问、完成和警告；批准与回答仍在 Mac 上完成。")
                    .font(.caption).foregroundStyle(.secondary)
                if push.configuration.enabled {
                    Toggle("仅在离开这台 Mac 时通知", isOn: $push.configuration.onlyWhenAway)
                    Text("锁屏、熄屏或闲置两分钟视为离开。测试通知不受此限制。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Toggle("审批", isOn: $push.configuration.approvals)
                        Toggle("提问", isOn: $push.configuration.questions)
                        Toggle("完成", isOn: $push.configuration.completions)
                        Toggle("警告", isOn: $push.configuration.warnings)
                    }.toggleStyle(.checkbox)
                    Toggle("包含对话详情", isOn: $push.configuration.includeDetails)
                    Text("默认仅发送 Codex 和项目名称；开启后会向 Bark 发送标题与内容片段。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    TextField("Bark 服务器", text: $push.configuration.server)
                        .textFieldStyle(.roundedBorder)
                    Text("默认 https://api.day.app；自建服务需填写 HTTPS 地址。")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("设备密钥（Bark 首页 URL 中的短代码）", text: $secrets.deviceKey)
                        .textFieldStyle(.roundedBorder)
                    Toggle("加密通知内容（AES-256-GCM）", isOn: $push.configuration.encrypted)
                        .onChange(of: push.configuration.encrypted) { _, value in
                            if value && secrets.encryptionKey.isEmpty { generateKey() }
                        }
                    if push.configuration.encrypted {
                        HStack {
                            SecureField("Key · 32 个字符", text: $secrets.encryptionKey).textFieldStyle(.roundedBorder)
                            Button("复制 Key") { copy(secrets.encryptionKey) }
                        }
                        HStack {
                            SecureField("IV · 12 个字符", text: $secrets.encryptionIV).textFieldStyle(.roundedBorder)
                            Button("复制 IV") { copy(secrets.encryptionIV) }
                        }
                        Button("生成新 Key 和 IV") { generateKey() }
                        Text("在 Bark 首页 → 推送加密中选择 AES256 / GCM / NoPadding，粘贴 Key 和 IV。每条消息自动使用独立 IV。更换 Key 后需同步手机配置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("保存连接") {
                            do { try push.saveSecrets(secrets); error = nil }
                            catch { self.error = error.localizedDescription }
                        }.disabled(!loaded)
                        Button(push.testing ? "发送中…" : "发送测试") { push.test(secrets: secrets) }
                            .disabled(push.testing || !loaded)
                        Spacer()
                        Link("安装 Bark", destination: URL(string: "https://apps.apple.com/app/id1403753865")!)
                    }
                    Text(error ?? push.status).font(.caption).foregroundStyle(error == nil ? Color.secondary : .orange)
                    Text("推送会保存到 Bark 历史记录。设备密钥和加密参数保存在本机钥匙串。已接受只表示服务器收件，手机通知权限仍需开启。Mac 完全睡眠或应用退出时无法发送。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        }
        .onAppear {
            guard !loaded else { return }
            do { secrets = try push.loadSecrets(); loaded = true }
            catch { self.error = error.localizedDescription }
        }
    }
    private func generateKey() {
        secrets.encryptionKey = IslandPhonePushPayload.randomASCII(count: 32)
        secrets.encryptionIV = IslandPhonePushPayload.randomASCII(count: 12)
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
