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

    static var nativeNotice: String {
        switch L10n.shared.language {
        case .zhHans: return "macOS 27 使用原生隐藏接口，需要辅助功能权限和有效的 Apple 团队签名。同一程序的多个图标会一起控制；Vorssaint 自身图标保留。"
        case .zhTW, .zhHK: return "macOS 27 使用原生隱藏介面，需要輔助使用權限與有效的 Apple 團隊簽章。同一程式的多個圖示會一起控制；Vorssaint 自身圖示保留。"
        default: return "macOS 27 uses native visibility, requiring Accessibility permission and a valid Apple team signature. Icons belonging to one app are controlled together; Vorssaint's own icons stay visible."
        }
    }

    static func nativeError(_ error: Error) -> String {
        let chinese: Bool
        switch L10n.shared.language {
        case .zhHans, .zhTW, .zhHK: chinese = true
        default: chinese = false
        }
        switch error as? MenuBarIconHidingError {
        case .accessibilityDenied:
            return chinese ? "请在系统设置 → 隐私与安全性 → 辅助功能中允许 Vorssaint，然后再次点击折叠。" : "Allow Vorssaint in System Settings → Privacy & Security → Accessibility, then retry."
        case .signatureIneligible:
            return chinese ? "当前应用签名不符合菜单栏隐藏要求。请使用带 Team ID 的 Apple Development 或 Developer ID 证书重新打包；自签名和临时签名不支持此功能。" : "This build needs an Apple Development or Developer ID team signature. Rebuild with that identity; self-signed and ad-hoc builds are unsupported."
        case .menuBarReadFailed:
            return chinese ? "无法读取当前屏幕的菜单栏图标。请确认辅助功能授权，展开原菜单栏后重试。" : "Could not read menu bar items on this display. Check Accessibility access, reveal the original menu bar, and retry."
        case .nativeAPIUnavailable:
            return chinese ? "当前 macOS 的原生菜单栏隐藏接口不可用，已保持展开。" : "Native menu bar visibility is unavailable on this macOS version. Icons remain expanded."
        case .invalidMarkerPosition: return current.placementError
        default:
            return chinese ? "系统拒绝了图标隐藏请求。已保持展开，请稍后重试。" : "The system rejected the menu bar visibility request. Icons remain expanded; please retry."
        }
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
