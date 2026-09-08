// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

struct PermissionDragGuideStrings {
    let language: AppLanguage
    private var simplified: Bool { language == .zhHans }
    private var traditional: Bool { language == .zhTW || language == .zhHK }
    private func value(_ zh: String, _ traditional: String, _ en: String) -> String {
        simplified ? zh : self.traditional ? traditional : en
    }
    var openStep: String { value("在系统设置中打开：", "在系統設定中開啟：", "In System Settings, open: ") }
    var dragStep: String {
        value("若列表中没有此 App，将下方卡片拖入列表。", "若清單中沒有此 App，將下方卡片拖入清單。",
              "If the app is missing, drag the card below into the list.")
    }
    var enableStep: String {
        value("开启 App 右侧的开关，并确认系统提示。", "開啟 App 右側的開關，並確認系統提示。",
              "Enable the app and confirm any system prompt.")
    }
    var dragLabel: String { value("拖入系统权限列表", "拖入系統權限清單", "Drag into the system permission list") }
    var revealApp: String { value("在访达中显示 App", "在 Finder 中顯示 App", "Show app in Finder") }
    var bundleRequired: String {
        value("请从安装后的 App 打开此引导。", "請從安裝後的 App 開啟此引導。", "Open this guide from the installed app.")
    }
    var repairNote: String {
        value("开关已开启但仍不可用？先删除列表中的旧 App 条目，再拖入当前 App，重新开启权限。",
              "開關已開啟但仍不可用？先刪除清單中的舊 App 項目，再拖入目前 App，重新開啟權限。",
              "Enabled but still unavailable? Remove the old app entry, drag in the current app, then enable access again.")
    }
    var restartNote: String {
        value("完成后请重新启动 App，以确认完全磁盘访问权限。", "完成後請重新啟動 App，以確認完整磁碟存取權限。",
              "Restart the app after enabling Full Disk Access to confirm it.")
    }
}
