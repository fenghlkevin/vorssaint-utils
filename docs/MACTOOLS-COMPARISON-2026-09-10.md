# MacTools 与 Vorssaint 功能对比

核对日期：2026-09-10。

对方依据：[MacTools 中文 README](https://github.com/ggbond268/MacTools/blob/main/README.zh-CN.md)，页面显示最近一次文档提交为 `1dcc20e40fbc8556045100b5b8671efe4c85085e`（2026-09-09）。本项目依据：当前工作区源码（HEAD `fcd95a0`，包含已有未提交修改）。

这是 README 宣称能力与本地源码的静态对比，未逐项运行两个应用，也不代表双方正式发行版均已交付。已覆盖表示核心用途已有实现，不表示全部细节一致；部分覆盖表示已有相关能力但存在明确缺口；未发现表示未找到对应产品入口或实现。用户自行编写脚本、跳转系统设置不算内置实现。

## 一、未发现对应内置功能

| MacTools 功能 | 我们缺少的能力 | 本地核对说明 |
| --- | --- | --- |
| 显示器分辨率 | 枚举并直接切换各显示器分辨率 | 有亮度控制；命令栏可打开显示器设置，未发现切换显示模式实现 |
| 原彩显示 | True Tone 快捷开关 | 未发现对应控制实现 |
| 夜览 | Night Shift 快捷开关 | 未发现对应控制实现 |
| 隐藏刘海 | 遮挡内建屏顶部刘海区域 | 灵动岛是信息展示功能，不等同于隐藏刘海 |
| 自动隐藏菜单栏 | 切换系统菜单栏自动隐藏 | 已有菜单栏图标折叠，不等同于隐藏整条菜单栏 |
| 自动隐藏程序坞 | 切换 Dock 自动隐藏 | Dock 预览读取该状态，但未发现修改入口 |
| 锁定程序坞 | 防止 Dock 跨显示器移动 | 未发现对应控制实现 |
| 台前调度 | Stage Manager 开关 | 窗口预览有兼容处理，未发现开关入口 |
| Cloudflare R2 上传 | S3 凭据、重命名、重名处理、进度取消、公开链接 | 现有截图／录屏分享不能等同于通用 R2 文件上传 |
| 运行链接 | 稳定的动作／工作流 URL API、参数预设链接 | 未发现对外动作 URL Scheme；打开普通链接是不同方向的功能 |
| 启动台 | 全屏／紧凑应用网格、分页、拖拽建文件夹 | 快捷面板是内置工具网格，命令栏是搜索启动应用，均不是 Launchpad 替代品 |
| 系统软重启 | 重启用户服务并恢复普通应用、菜单栏应用 | 有个别应用重启，未发现用户会话服务级恢复工具 |
| 修复损坏应用 | 选择任意 .app 移除隔离属性的专用工具 | 自更新代码清理自身扩展属性，不是通用应用修复入口 |
| zsh 配置 | 配置文件编辑、语法高亮、片段、保存前备份 | Homebrew 相关代码引用 .zshrc，不是配置编辑器 |
| 状态栏图标自定义 | 自选图片、GIF／MP4、在线素材、自动扣背景 | 有系统指标与电池图标样式，未发现用户素材图标功能 |

## 二、已有基础，但未完整覆盖

| MacTools 功能 | 我们已有 | 明确差距或待核实细节 |
| --- | --- | --- |
| Mac 设置 | 命令栏搜索系统设置页面；少量直接开关 | 缺少 README 所述 47 项直接控制、固定控制、最近更改、类型化配置比较／应用／验证／回滚 |
| 模拟鼠标中键 | 三指按压、三／四指轻点 | 未发现五指轻点；设备重连等恢复行为未做运行验证 |
| 触控板手势 | 专用中键功能 | 缺少 TipTap、通用三至五指双击／长触映射、测试模式和手势配置库 |
| 自定义快捷操作 | 全局快捷键、鼠标侧键映射、径向菜单、滚动增强 | 缺少覆盖键盘／触控板／鼠标／滚动的统一动作映射和统一应急停用机制 |
| 磁盘清理 | 缓存、日志、开发缓存、残留与废纸篓处理 | 未发现项目级 node_modules 和通用构建输出扫描；不能把缓存目录清理算作项目清理 |
| Xcode 清理 | DerivedData、DocumentationCache、CoreSimulator 缓存、设备支持缓存 | 未发现 Archives、预览缓存专项分类，以及 Xcode 运行时统一禁用清理 |
| IP 检测 | 网络吞吐、测速、进程网络统计 | 缺少国内／国际出口 IP、局域网 IP 汇总、归属地、运营商、ASN 检测与复制面板 |
| 窗口布局 | 半屏、四角、三分屏、六分屏、跨屏、恢复、修饰键鼠标操作、边缘吸附 | 未发现四分之一列、固定坐标预设及宽高步进命令；已有鼠标手势需要鼠标事件，不等同于其纯修饰键免点击移动；缺外部 Run Link／工作流调用 |
| 应用快捷键 | 命令栏应用启动与行级全局快捷键 | 应用已在前台时再次按键隐藏的同键切换语义未确认 |
| 操作与快捷键 | 命令栏发现执行、行级快捷键、快捷键设置 | 缺少统一插件动作发布、Apple 快捷指令／Siri 的 App Intents 接入、可迁移参数及跨进程熔断 |
| 自动化 | 输入法、保持唤醒、电池、离开锁定、清理等专用规则 | 缺少通用命名工作流、多步骤编排、条件与多类触发器、逐步历史、测试／停止界面 |
| 操作网格 | 三列快捷面板、排序隐藏、方向键／数字键；径向菜单支持更多目标 | 核心快捷入口已覆盖，但网格不能任意绑定其所述统一动作与工作流 |
| 已存脚本 | 命令栏保存脚本文件链接、传参执行并读取输出 | 缺少应用内多语言脚本文本库、主动停止、可调超时，以及脚本发布为跨入口动作 |
| 右键工具 | Finder 剪切粘贴、重命名、粘贴图片为文件；命令栏可操作文件 | 未发现 Finder 右键扩展，缺少 README 所列多种空文件模板、终端打开、应用打开、路径复制的一体化右键菜单 |
| 启动项管理 | 清理器扫描孤立 LaunchAgent／LaunchDaemon，并清理残留 | 缺少全部启动项浏览、字段解释、正常用户级任务启停管理 |
| 日历组件 | 灵动岛读取当天日程、会议提醒／跳转 | 未发现农历、节假日；月历组件完整交互未确认 |
| 系统状态 | CPU／GPU／内存／磁盘／网络／电池、进程、图表及菜单栏配置 | 核心用途已覆盖；其 30 分钟／2 小时／24 小时详情、固定读数和双数值样式不判定为完全一致 |
| 活动统计 | 灵动岛有 Codex 活动服务与日志读取 | 缺少键盘次数、鼠标／滚动统计、前台应用时长报表，以及多 AI 工具统一 Hook 统计 |
| 设备电量 | Mac 电池、HID／蓝牙外设电量 | 缺少已信任 iPhone／iPad／Apple Watch 的 USB／Wi-Fi 聚合、雷柏 VT 专项；AirPods 分体值当前汇总为单值，未见左右耳／盒独立展示 |
| 退出应用 | 命令栏退出应用、强制结束进程、关闭窗口自动退出 | 缺少带反选、多实例合并的一站式批量退出面板；不能把强制杀进程算作正常批量退出 |
| 插件与设置 | 内置功能中心启停／卸载、权限管理、设置备份、搜索和快捷键 | 缺少第三方插件安装更新、插件动作与表单协议，以及自动化／Run Link 等依赖感知备份；内置模块不等于开放插件生态 |

## 三、核心用途已有覆盖

| MacTools 功能 | Vorssaint 对应能力 |
| --- | --- |
| 显示器亮度 | 内建／外接屏亮度、DDC/CI、软件 Gamma 调暗、亮度快捷键；另有额外亮度 |
| 显示器休眠 | 快捷开关中立即关闭显示器 |
| 深色模式 | 直接切换系统外观 |
| 阻止休眠 | 保持唤醒、定时、合盖与电源显示策略；具体模式和实验性虚拟屏实现不逐项视为相同 |
| 清洁模式 | 清洁模式覆盖屏幕、屏蔽输入 |
| 鼠标增强 | 滚动方向翻转、水平控制、平滑滚动及应用例外 |
| 系统静音 | 音量混合器包含系统输出音量／静音控制 |
| 麦克风静音 | 麦克风静音功能 |
| 应用音量 | 应用音量混合器，另支持按应用选择输出设备 |
| 推出磁盘 | 快捷开关推出外接磁盘，支持排除列表 |
| 清空废纸篓 | 快捷开关及清理器中的清空操作 |
| 清空剪贴板 | 剪贴板清理／自动清理能力；清空当前内容与删除历史的范围应分别确认 |
| 翻译 | 划词、输入、剪贴板、OCR；Apple 本地、AI／DeepSeek、本机 Codex CLI |
| 自动切换输入法 | 应用记忆／固定输入法，并扩展网站规则与英文标点 |
| 锁定屏幕 | 快捷锁屏，并有蓝牙离开自动锁定 |
| 风扇控制 | 风扇监测、控制服务与特权辅助组件；硬件支持需实机验证 |
| 电池充电上限 | 电池管理、充电限制与自动化；恢复充电策略与 MacTools 描述不保证相同 |
| 多语言 | 多语言资源、语言设置；双方支持的具体语言集合不完全相同 |

## 四、README 功能表之外的补充差距

| 能力 | 对比结论 |
| --- | --- |
| 主题定制 | MacTools 声明浅深色分别选主题、十款配色、导入 iTerm／Base16／Base24；我们未发现同等主题导入功能 |
| 实验性 CLI | MacTools 声明 Nightly 独立 CLI：doctor、动作发现、受限执行、JSON；我们未发现产品级对外动作 CLI。构建脚本和翻译调用 Codex CLI 不算此项 |

## 五、建议排期

以下是基于本地现有基础的工程判断，未估算工作量，也未逐项验证对方体验。

1. **先补直接工具缺口**：显示器分辨率、原彩／夜览、Dock／菜单栏控制、IP 信息面板。这些功能用途明确，适合独立交付；系统私有接口兼容性仍需验证。
2. **完善已有模块**：Finder 右键工具、Xcode 专项清理、启动项管理、五指中键与通用手势、外设分体电量。
3. **单独规划架构能力**：统一动作注册 → Run Link／Apple 快捷指令 → 脚本库 → 通用工作流 → 第三方插件。建议共享动作层，避免每个入口各自维护执行逻辑。
4. **按实际需求取舍**：R2 上传、Launchpad 替代、动态图标、zsh 编辑器、系统软重启。它们是功能差异，但不自动等于必须开发。

我们已有且对方该 README 功能表未列出的能力包括：截图标注／滚动截图／录屏编辑、剪贴板历史、文件暂存架、应用切换器与 Dock 预览、OCR／取色、Homebrew 管理、应用卸载与第三方应用更新、链接清理、DMG 安装、文本片段、键盘防抖等。这里只能判断“对方文档未列出”，不能据此断言其源码没有。

## 六、本地核对入口

- [本项目说明](../README.md)、[功能目录](../Sources/Vorssaint/Core/FeatureCatalog.swift)、[功能运行管理](../Sources/Vorssaint/App/FeatureRuntime.swift)
- [快捷开关](../Sources/Vorssaint/Services/QuickTools/QuickTogglesService.swift)、[快捷面板](../Sources/Vorssaint/Services/QuickTools/QuickLauncherService.swift)、[径向菜单](../Sources/Vorssaint/Services/RadialMenu/RadialMenuSupport.swift)
- [系统设置搜索](../Sources/Vorssaint/Services/CommandBar/CommandBarSystemSettings.swift)、[行级快捷键](../Sources/Vorssaint/Services/CommandBar/CommandBarRowShortcuts.swift)、[脚本执行](../Sources/Vorssaint/Services/CommandBar/CommandBarScriptRunner.swift)
- [清理器](../Sources/Vorssaint/Services/Cleaner/JunkCleaner.swift)、[开发缓存范围](../Sources/Vorssaint/Services/Cleaner/CleanerPolicy.swift)
- [中键识别规则](../Sources/Vorssaint/Services/MiddleClick/MiddleClickSupport.swift)、[窗口布局](../Sources/Vorssaint/Services/WindowLayout/WindowLayoutSupport.swift)、[窗口交互](../Sources/Vorssaint/Services/WindowLayout/WindowLayoutService.swift)
- [外设电量](../Sources/Vorssaint/Services/Metrics/PeripheralBatterySupport.swift)、[网络测速](../Sources/Vorssaint/Services/Metrics/SpeedTest.swift)、[日程服务](../Sources/Vorssaint/Services/DynamicIsland/TimeReminderService.swift)、[Codex 活动](../Sources/Vorssaint/Services/DynamicIsland/CodexIslandService.swift)
- [亮度](../Sources/Vorssaint/Services/Display/BrightnessSupport.swift)、[音量混合器](../Sources/Vorssaint/Services/Audio/AppVolumeMixer.swift)、[电池管理说明](battery-management.md)、[电源显示说明](power-display-management.md)
