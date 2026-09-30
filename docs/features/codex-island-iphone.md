# Codex 灵动岛与 iPhone 通知

范围仅限 Codex。灵动岛的外观目标仍为 Vibe Island：黑色一体面板、紧凑会话行、按内容展开。音乐、定时器和备忘继续保留。

## Codex

审批显示端：设置 → 灵动岛 → AI Hook → 审批显示端。默认保留“灵动岛”；选择“Codex 原生”后，Vorssaint 的 PermissionRequest Hook 立即退出，不给出允许或拒绝决定，交还 Codex 原生审批流程。正在灵动岛等待的请求也会交回；已交回的请求不会因切回灵动岛而被重新接管。设置跨重启保留，不修改 hooks.json，不改变信任哈希。

此设置只控制 Vorssaint；其他程序的审批 Hook 仍可能等待。Computer Use 应用授权始终在 Codex 原生界面处理。原生模式下，Vorssaint 不创建对应审批卡片，也不会发送该审批的 Bark 通知，任务状态与完成通知仍保留。

- Hook 安装在 `~/.codex/hooks.json`，只更新 Vorssaint 自己的条目。若 Codex 要求信任，请在 Codex 的 `/hooks` 中审阅并批准预期条目；应用不修改信任策略。
- 设置页与灵动岛会通过 Codex 官方 `hooks/list` 检查 Vorssaint 的 PermissionRequest 是否启用且受信任。`modified` 和 `untrusted` 会显示“审批未接通”；其他应用的已信任 Hook 不算接通。每分钟复查，可手动重新检查。兼容新版 `Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex` 与旧版 `Resources/codex`；未找到命令行与查询失败分别提示，不再当成未信任。配置写入成功不代表已连接，受信任也仍需真实审批事件验证。
- 审批显示工具操作，支持查看正文。每次请求生成独立 UUID，允许／拒绝仅响应这次请求；界面先显示“已发送”，Hook 读到后再显示“Codex 已接收”。超时回到 Codex 原生审批。
- 接收端通过本地心跳确认存活；未运行时 Hook 不等待，也不会自动同意。
- 打开命令行管理 `/hooks`、尚未提交任务的空会话不会计入运行中；SessionStart 仅记录导航信息。
- 会话状态同时由 Hook 和增量 JSONL 提供。显式 `request_user_input` 调用显示待回答，并在对应响应后解除；异步提问在新用户消息或回合状态更新时解除。无法从日志识别的自定义提问流程仍需返回 Codex 查看。
- 桌面任务通过 `codex://threads/<id>` 返回会话。Terminal.app 在 Hook 携带 TTY 时定位标签页，其余情况保留 Codex 桌面跳转。
- 子 Agent 的 Stop 不会再把主任务误标为完成。

## iPhone 设置

入口：设置 → 灵动岛 → AI Hook → 通知 · iPhone。

1. 在 iPhone 安装 Bark 并允许通知。
2. 开启“通知我的 iPhone”，填写设备密钥：Bark 首页示例地址中域名后的短代码，不是设置页的 Device Token。
3. 公共服务器保持 `https://api.day.app`；自建服务填写 HTTPS 基础地址，可带反向代理路径，不含设备密钥。
4. 保存连接，点击“发送测试”。“Bark 已接受”代表服务器接收成功，需在手机上确认横幅。

推送默认关闭；开启后的默认规则为仅离开 Mac 时通知（锁屏、熄屏或闲置 120 秒），审批、提问、完成、警告全部选中。测试不受离开检测和事件开关限制。

默认内容只包含 Codex 事件类别及项目名。选择“包含对话详情”后才附上任务标题和片段。敏感配置保存在本机钥匙串，HTTP 错误不会展示服务器返回的原文或设备密钥。请求为 JSON POST，禁止 HTTP 和重定向。

同一会话使用稳定通知 ID 更新通知；请求已处理或再次开始任务时尝试撤回。更新需 Bark 1.5.2 / bark-server 2.2.5 以上；撤回依赖 Bark 后台 App 刷新和 iOS 的后台调度。Mac 完全睡眠、应用退出或网络不可达时不能及时推送；不会补发启动前历史消息。

## 加密

开启 AES-256-GCM 后生成 32 字符 Key 和 12 字符 IV。到 Bark 首页“推送加密”选择 AES256、GCM、NoPadding，粘贴并保存。每条通知使用独立随机 IV，经 Bark 的 `iv` 参数覆盖默认 IV；密文格式为 ciphertext + 16 字节 tag 的 Base64。服务器仍可见设备密钥、通知 ID 和投递元数据。撤回只发送 ID 与删除指令，不包含会话内容。

iPhone 仅负责提醒，不能远程批准或回答。

## 验证

执行 `bash Tools/test-island.sh`：布局优先级、日志增量读取、请求 ID 隔离、审批响应协议、提问状态、HTTPS 校验、默认内容隐私、AES-GCM、模拟 HTTP 成败，以及真实 Hook 子进程并发响应／接收端失联测试。所有网络测试使用 URLProtocol 模拟，不发送真实通知；Hook 测试使用临时目录，不改动真实 Codex 配置。

构建：`zsh build.sh --dev`。实机联调还需用户的 Bark 设备密钥和 Codex 的 Hook 信任。

参考：

- https://vibeisland.app/zh/docs/iphone-notifications/
- https://learn.chatgpt.com/docs/hooks
- https://github.com/Finb/Bark/blob/master/docs/en-us/params.md
- https://github.com/Finb/Bark/blob/master/NotificationServiceExtension/Processor/CiphertextProcessor.swift
- https://github.com/Finb/Bark/blob/master/Model/Algorithm.swift
