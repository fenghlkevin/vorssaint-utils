// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct MenuBarIconCollapserStrings {
    let title: String
    let enable: String
    let caption: String
    let configuration: String
    let instruction: String
    let collapse: String
    let expand: String
    let placementReady: String
    let placementError: String
    let checkPosition: String
    let automaticCollapse: String
    let never: String
    let secondsFormat: String
    let oneMinute: String
    let interactionHelp: String
    let dividerTooltip: String

    func delayTitle(_ seconds: Int) -> String {
        if seconds == 0 { return never }
        if seconds == 60 { return oneMinute }
        return String(format: secondsFormat, seconds)
    }

    static var current: MenuBarIconCollapserStrings {
        strings(for: L10n.shared.language)
    }

    static func strings(for language: AppLanguage) -> MenuBarIconCollapserStrings {
        switch language {
        case .zhHans:
            return MenuBarIconCollapserStrings(
                title: "折叠菜单栏图标",
                enable: "启用菜单栏图标折叠",
                caption: "隐藏分隔按钮左侧的菜单栏图标，Vorssaint 和分隔按钮始终保留为恢复入口。",
                configuration: "折叠设置",
                instruction: "开启后，按住 ⌘ 拖动菜单栏中的双箭头，把它放在 Vorssaint 图标左侧。需要隐藏的图标应放在双箭头左侧。",
                collapse: "折叠图标",
                expand: "展开图标",
                placementReady: "分隔按钮位置正确。",
                placementError: "请先按住 ⌘，将双箭头拖到 Vorssaint 图标左侧。为避免隐藏恢复入口，本次没有折叠。",
                checkPosition: "检查位置",
                automaticCollapse: "展开后自动折叠",
                never: "从不",
                secondsFormat: "%d 秒",
                oneMinute: "1 分钟",
                interactionHelp: "左键双箭头可展开或折叠；右键双箭头会折叠；折叠后右键 Vorssaint 图标会展开。",
                dividerTooltip: "展开或折叠菜单栏图标")
        case .zhTW:
            return MenuBarIconCollapserStrings(
                title: "收合選單列圖示",
                enable: "啟用選單列圖示收合",
                caption: "隱藏分隔按鈕左側的選單列圖示，Vorssaint 與分隔按鈕會保留為還原入口。",
                configuration: "收合設定",
                instruction: "開啟後，按住 ⌘ 拖動選單列中的雙箭頭，將它放在 Vorssaint 圖示左側。要隱藏的圖示應位於雙箭頭左側。",
                collapse: "收合圖示",
                expand: "展開圖示",
                placementReady: "分隔按鈕位置正確。",
                placementError: "請先按住 ⌘，將雙箭頭拖到 Vorssaint 圖示左側。為避免隱藏還原入口，本次沒有收合。",
                checkPosition: "檢查位置",
                automaticCollapse: "展開後自動收合",
                never: "永不",
                secondsFormat: "%d 秒",
                oneMinute: "1 分鐘",
                interactionHelp: "左鍵雙箭頭可展開或收合；右鍵雙箭頭會收合；收合後右鍵 Vorssaint 圖示會展開。",
                dividerTooltip: "展開或收合選單列圖示")
        case .zhHK:
            return MenuBarIconCollapserStrings(
                title: "收合選單列圖示",
                enable: "啟用選單列圖示收合",
                caption: "隱藏分隔按鈕左側的選單列圖示，Vorssaint 與分隔按鈕會保留為還原入口。",
                configuration: "收合設定",
                instruction: "開啟後，按住 ⌘ 拖動選單列中的雙箭頭，將它放在 Vorssaint 圖示左側。要隱藏的圖示應位於雙箭頭左側。",
                collapse: "收合圖示",
                expand: "展開圖示",
                placementReady: "分隔按鈕位置正確。",
                placementError: "請先按住 ⌘，將雙箭頭拖到 Vorssaint 圖示左側。為避免隱藏還原入口，本次沒有收合。",
                checkPosition: "檢查位置",
                automaticCollapse: "展開後自動收合",
                never: "永不",
                secondsFormat: "%d 秒",
                oneMinute: "1 分鐘",
                interactionHelp: "左鍵雙箭頭可展開或收合；右鍵雙箭頭會收合；收合後右鍵 Vorssaint 圖示會展開。",
                dividerTooltip: "展開或收合選單列圖示")
        default:
            return MenuBarIconCollapserStrings(
                title: "Collapse menu bar icons",
                enable: "Enable menu bar icon collapsing",
                caption: "Hides menu bar icons to the left of the divider. Vorssaint and the divider stay visible as the way back.",
                configuration: "Collapse settings",
                instruction: "After enabling, hold Command and drag the double chevron to the left of the Vorssaint icon. Put the icons to hide on the chevron's left.",
                collapse: "Collapse icons",
                expand: "Show icons",
                placementReady: "The divider is in a safe position.",
                placementError: "First Command-drag the double chevron to the left of Vorssaint. Nothing was collapsed, so the recovery control stays visible.",
                checkPosition: "Check position",
                automaticCollapse: "Collapse automatically after showing",
                never: "Never",
                secondsFormat: "%d seconds",
                oneMinute: "1 minute",
                interactionHelp: "Left-click the chevrons to show or collapse. Right-click the chevrons to collapse; while collapsed, right-click Vorssaint to show the icons.",
                dividerTooltip: "Show or collapse menu bar icons")
        }
    }
}
