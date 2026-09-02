<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/readme/logo-dark.svg">
    <img src="docs/assets/readme/logo.svg" width="220" alt="Vorssaint 标志">
  </picture>
</p>

<h1 align="center">Vorssaint</h1>

<p align="center">
  一个菜单栏图标，集成十余款常用 Mac 工具的能力。<br>
  免费、开源，所有核心处理均在本机完成。
</p>

<p align="center">
  <a href="https://vorssaint.com">官网</a> · <a href="#安装">安装</a> ·
  <a href="#主要功能">功能</a> · <a href="#隐私与权限">隐私</a> ·
  <a href="CHANGELOG.md">更新日志</a> · <a href="mailto:hello@vorssaint.com">联系作者</a>
</p>

<p align="center">
  <a href="https://github.com/vorssaintapp/vorssaint-utils/releases"><img src="https://img.shields.io/github/v/release/vorssaintapp/vorssaint-utils?label=release&color=4c8dff" alt="最新版本"></a>
  <a href="https://github.com/vorssaintapp/vorssaint-utils/releases"><img src="https://img.shields.io/github/downloads/vorssaintapp/vorssaint-utils/total?color=4c8dff" alt="下载次数"></a>
  <a href="https://github.com/vorssaintapp/vorssaint-utils/actions/workflows/ci.yml"><img src="https://github.com/vorssaintapp/vorssaint-utils/actions/workflows/ci.yml/badge.svg?branch=main&event=push" alt="CI 状态"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-black" alt="macOS 14 及以上，Apple 芯片">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="GPL 3.0 或更高版本"></a>
</p>

<p align="center">
  <img src="docs/assets/readme/panel-mixer.png" width="196" alt="按应用调节音量">
  <img src="docs/assets/readme/panel-system.png" width="196" alt="系统监控面板">
  <img src="docs/assets/readme/panel-controls.png" width="196" alt="窗口与 Dock 控制">
  <img src="docs/assets/readme/panel-utilities.png" width="196" alt="实用工具面板">
</p>

Vorssaint 是一款面向 macOS 的一体化菜单栏工具，整合了应用音量、系统监控、窗口管理、剪贴板、截图录屏、文件处理、应用卸载等能力。无需注册账号、没有遥测，也不需要订阅。

## 按需启用

“功能中心”可以单独安装或卸载完整功能模块。卸载后，该模块会从界面中消失并停止加载，不再占用 CPU、内存或电量；已有设置不会删除，重新安装即可恢复。

首次启动可选择“基础”“窗口”或“省电静音”预设，也可以逐项选择功能。应用只申请所选功能真正需要的权限，并标明功能启用后的能耗类型。面板分区支持排序与隐藏，设置也可以导出后在另一台 Mac 上导入。

<p align="center"><img src="docs/assets/readme/features-hub.png" width="720" alt="功能中心"></p>

## 主要功能

### 声音

- **应用音量混合器**：分别调整系统及每个应用的音量，支持精确百分比、超过 100% 增益、应用隐藏和系统声音输出分流。
- **按应用选择输出设备**：例如让音乐走扬声器、通话走耳机。
- **输出设备与麦克风**：快捷键轮换输出设备、固定首选输入设备、一键静音全部麦克风。
- **音乐应用拦截**：阻止耳机连接时“音乐”应用自动启动。

### 系统监控

- **性能与硬件状态**：CPU、GPU、内存、交换空间、磁盘、温度、电池健康度、循环次数及功耗历史。
- **风扇控制（测试功能）**：实时转速、固定转速和自定义温度曲线。
- **菜单栏读数与提醒**：显示用量、温度、电池时间、风扇转速，并在高负载、高温、内存压力、低磁盘或低电量时通知。
- **网络工具**：实时速率、会话流量统计和网速测试。

### 窗口与 Dock

- **应用切换器**：增强版 ⌘Tab，支持实时窗口缩略图、多窗口、搜索、按应用规则和多显示器定位。
- **窗口布局**：半屏、三分屏、六分屏、角落、居中、跨屏移动、边缘吸附、间距、快捷键及布局恢复。
- **Dock 窗口预览与点击动作**：预览、选择和拖动窗口，也可最小化、隐藏或循环切换窗口。
- **窗口最大化与关闭即退出**：绿色按钮最大化时不新建“空间”，也可让指定应用在最后一个窗口关闭后退出。

<p align="center"><img src="docs/assets/readme/window-switcher.gif" width="540" alt="窗口切换器演示"></p>

### 键盘与鼠标

- 文本片段自动展开、平滑滚动、鼠标跟随聚焦、滚轮方向独立设置。
- **输入法自动切换**：按软件或浏览器网站设置输入法规则，网站规则优先；支持跟随上次使用的输入法，以及强制英文标点。
- 鼠标侧键导航、自定义鼠标按键快捷键、三指中键，并可为特定应用设置例外。
- 键盘防连击，以及把 Caps Lock 或右侧修饰键变成组合修饰键的“超级键”。
- 在统一页面管理所有已安装功能的全局快捷键。

### 剪贴板、文件与链接

- **剪贴板历史**：本地保存文本、图片和文件，支持固定、搜索、预览、编辑和快速粘贴。
- **自动清空与纯文本粘贴**：按时间、睡眠、息屏或锁屏清空系统剪贴板；快捷键移除格式后粘贴。
- **文件暂存架与 Finder 增强**：临时存放拖拽内容，使用 ⌘X/⌘V 移动文件、F2 重命名，把图片粘贴成 PNG。
- **链接清理与 DMG 安装**：移除跟踪参数；一键安装磁盘映像中的应用并清理下载文件。

### 日常工具

- **命令栏**：搜索并执行功能、应用、窗口、菜单命令、表情、文本片段、剪贴板和文件；支持计算、换算、日期、本地脚本和系统设置入口。
- **快捷面板、快捷开关与径向菜单**：集中调用常用功能、系统开关、应用、文件、链接和快捷键。
- **菜单栏图标折叠**：用可拖动的分隔按钮收起其左侧图标，并始终保留 Vorssaint 和分隔按钮作为恢复入口；可在展开后延时自动折叠。
- **截图与录屏**：区域、窗口和全屏捕获，滚动截图、OCR、二维码、标注、遮挡、裁剪、指针平滑、自动缩放、音轨编辑及 GIF/视频导出。
- **屏幕取色、摄像头预览与便笺**：在本地完成取色、预览和临时文本记录。
- **应用更新、清理器与卸载器**：聚合更新来源，查找缓存、日志和应用残留，并在确认后移入废纸篓。
- **媒体与 Homebrew 工具**：压缩、裁剪和转换视频或图片，制作 GIF、添加水印，并通过图形界面管理 formula 和 cask。
- **清洁模式**：清洁设备时锁定键盘并黑屏；另提供进程结束、临时粘贴等实用能力。

### 电源、显示与连接

- **保持唤醒**：按时长、外接显示器或电源状态保持 Mac 唤醒，支持合盖工作及菜单栏倒计时。
- **离开自动锁定**：监测选定蓝牙设备的距离或失联状态，在设备离开时倒计时锁定 Mac；设备返回后可请求唤醒显示器，并支持多设备策略、误锁保护、通知和节能模式。
- **显示器控制**：调整内外置显示器亮度、开关单个显示器，并让亮度键跟随鼠标所在屏幕。
- **额外亮度**：利用 MacBook Pro XDR 屏幕的 HDR 余量突破常规最高亮度。
- **睡眠时关闭蓝牙**：睡眠后暂时关闭蓝牙，唤醒时仅恢复由 Vorssaint 关闭的状态。

## 截图与滚动截图

以下说明对应当前源码开发版，已发布版本可能尚未包含全部调整。

### 原位编辑

通过“屏幕捕捉”中配置的快捷键启动截图，可拖选区域或点击识别出的窗口。未选中区域使用统一灰色遮罩；选区确定后直接在原位编辑，可继续调整截图范围。

- 提供矩形、椭圆、直线、箭头、画笔、荧光笔、文本、数字标点、备注、马赛克、放大镜和文字水印。
- 选中已有标注后可移动、调整样式或按 Delete 删除；文本和备注可再次进入编辑。工具样式记住上次使用的设置。
- 工具栏采用统一单色矢量图标，悬停可查看功能名称；样式选项在使用对应工具时显示。
- 点击对号完成并复制到剪贴板；点击保存按钮直接保存到 macOS“下载”目录。结果预览可再次打开原位编辑界面。

### 滚动截图

选定区域后点击工具栏中的滚动截图图标，再选择纵向或横向。横向模式支持左右滑动，也可将普通鼠标的纵向滚轮转换为横向输入。

滚动期间，侧边预览展示累计合并结果，并根据选区两侧空间安排位置。只允许选区内的相应方向滚动及截图工具栏操作，拦截后台点击、拖拽和常规快捷键；按 Esc 取消、回车或对号完成，退出后恢复正常操作。

**限制：**拼接依赖相邻画面的可识别重叠内容。大面积空白、重复文本、动态内容或滚动过快可能无法可靠匹配；此时保留已经确认的合并结果，不强行扩展长图。横向画面缺少足够特征时可能仅保留首帧。建议减慢滚动，并尽量包含有区别的内容。

### 诊断日志

在“设置 → 屏幕捕捉 → 截图诊断日志”开启或关闭记录，并可点击“打开日志目录”。未设置该选项时默认关闭。

```text
~/Library/Logs/Vorssaint/ScreenshotDiagnostics/
```

每次滚动会话使用独立的时间戳与 UUID 子目录，包含 `events.jsonl`，以及原始滚动帧、合并预览、完成图和编辑交接图的无损 PNG。记录包括当前滚动方向、匹配位移和图像尺寸，便于定位预览与最终结果不一致的问题。

**隐私与空间：**日志含实际屏幕内容，仅保存于本机，不自动上传。单次会话图片写入上限为 2 GiB，达到上限后仅继续记录事件；记录可能影响截图速度。关闭开关会停止新增记录，但不会删除已有日志。分享日志前请检查敏感内容，排查结束后可手动清理会话目录。

## 安装

使用 [Homebrew](https://brew.sh)：

```sh
brew install --cask vorssaint
```

也可以从 [Releases 页面](https://github.com/vorssaintapp/vorssaint-utils/releases) 下载磁盘映像，然后将 Vorssaint 拖入“应用程序”。正式构建已使用 Apple Developer ID 签名并通过公证。

## 卸载

```sh
brew uninstall --cask vorssaint
```

如需同时清除设置和权限，可在源码目录运行：

```sh
./Tools/uninstall.sh
```

## 隐私与权限

Vorssaint 默认在本机处理数据，不要求账号，不包含分析或跟踪。只有更新检查、测速、Homebrew 操作及临时截图/录屏分享等明确功能会访问网络，详见[隐私说明](docs/PRIVACY.md)。

所有 macOS 权限均为可选，并会说明用途和关联功能。部分能力需要“辅助功能”“屏幕与系统音频录制”“输入监控”等权限，完整说明见[权限指南](docs/PERMISSIONS.md)。

## 系统要求与源码构建

- Apple 芯片 Mac
- macOS 14 Sonoma 或更高版本
- 源码构建需要 Xcode Command Line Tools

开发构建使用独立名称和 Bundle ID，可以与正式版共存：

```sh
./build.sh --dev --install
```

运行项目测试：

```sh
./build.sh --test
```

开发版默认使用稳定的本地签名身份 `Vorssaint Utils Signing`。如果现有开发版使用 Apple Development 证书，可明确指定钥匙串中同一证书的名称或标识：

```sh
VORSSAINT_DEV_SIGNING_IDENTITY='你的现有开发签名身份' ./build.sh --dev --install
```

应沿用原 Bundle ID 和签名身份，避免 macOS 将更新版视为另一个应用，导致权限需要重新授权。正式版构建优先使用已安装的 Developer ID。

测试命令同时运行基础回归测试与滚动拼接测试，覆盖双向滚动、反向回滚、画布不缩小、像素保留和尺寸上限。也可在运行测试后用本地诊断日志回放重复文本横向回归（不会上传日志）：

```sh
./build/scrolling-stitch-tests --ambiguous-horizontal /绝对路径/到/重复文本诊断会话
```

该回放模式专门断言模糊重复内容不产生错误横向扩展，不用于验证普通横向截图。

## 文档与支持

- [更新日志](CHANGELOG.md) · [隐私说明](docs/PRIVACY.md) · [权限指南](docs/PERMISSIONS.md)
- [故障排除](docs/TROUBLESHOOTING.md) · [贡献指南](CONTRIBUTING.md)
- [支持渠道](SUPPORT.md) · [安全问题报告](SECURITY.md)

欢迎提交 Bug、功能建议、翻译和 Pull Request。私密问题或合作事宜可发送邮件至 [hello@vorssaint.com](mailto:hello@vorssaint.com)，也可以加入 [Discord 社区](https://discord.gg/M6BwWH4BJp)。

## 致谢与许可证

应用图标由 [@divisionseven](https://github.com/divisionseven) 设计。源代码采用 [GPL-3.0-or-later](LICENSE) 许可证，版权归 Vorssaint（2026）所有；名称、标志及视觉形象另受[商标说明](TRADEMARKS.md)约束。

<p align="center"><sub>由 <a href="https://x.com/vorssaint">@vorssaint</a> 制作</sub></p>
