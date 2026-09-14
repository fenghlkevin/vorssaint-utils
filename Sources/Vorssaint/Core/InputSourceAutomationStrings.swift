// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct InputSourceAutomationStrings {
    let pageTitle: String
    let enable: String
    let description: String
    let appRules: String
    let addApp: String
    let chooseApp: String
    let websiteRules: String
    let noAppRules: String
    let noWebsiteRules: String
    let defaultInputSource: String
    let followLastUsed: String
    let followLastUsedHint: String
    let forceEnglishPunctuation: String
    let remove: String
    let permissionHint: String

    static func current(_ language: AppLanguage) -> InputSourceAutomationStrings {
        switch language {
        case .zhHans:
            return .init(pageTitle: "输入法自动切换", enable: "启用输入法自动切换",
                         description: "切换软件或浏览器网站时，自动使用已设置的默认输入法。网站规则优先于软件规则。",
                         appRules: "软件规则", addApp: "添加软件", chooseApp: "选择要添加的软件",
                         websiteRules: "网站规则",
                         noAppRules: "还没有软件规则。点击“添加软件”创建规则。",
                         noWebsiteRules: "还没有网站规则。切换到浏览器网站后，可从菜单栏输入法 Tab 设置当前域名。",
                         defaultInputSource: "输入法策略", followLastUsed: "跟随上一次使用",
                         followLastUsedHint: "记住你在这个软件或网站中最后手动选择的输入法。",
                         forceEnglishPunctuation: "强制英文标点", remove: "移除",
                         permissionHint: "网站识别和强制英文标点需要“辅助功能”权限。")
        case .zhTW, .zhHK:
            return .init(pageTitle: "輸入法自動切換", enable: "啟用輸入法自動切換",
                         description: "切換軟件或瀏覽器網站時，自動使用已設定的預設輸入法。網站規則優先於軟件規則。",
                         appRules: "軟件規則", addApp: "新增軟件", chooseApp: "選擇要新增的軟件",
                         websiteRules: "網站規則",
                         noAppRules: "尚未設定軟件規則。點擊「新增軟件」建立規則。",
                         noWebsiteRules: "尚未設定網站規則。切換到瀏覽器網站後，可從選單列輸入法 Tab 設定目前網域。",
                         defaultInputSource: "輸入法策略", followLastUsed: "跟隨上一次使用",
                         followLastUsedHint: "記住你在這個軟件或網站中最後手動選擇的輸入法。",
                         forceEnglishPunctuation: "強制英文標點", remove: "移除",
                         permissionHint: "網站識別和強制英文標點需要「輔助使用」權限。")
        default:
            return .init(pageTitle: "Input Source Automation", enable: "Enable input source automation",
                         description: "Automatically use the configured input source when switching apps or websites. Website rules take priority over app rules.",
                         appRules: "App rules", addApp: "Add App", chooseApp: "Choose an app to add",
                         websiteRules: "Website rules",
                         noAppRules: "No app rules yet. Click Add App to create one.",
                         noWebsiteRules: "No website rules yet. Open a website, then configure its domain from the menu bar Input Source tab.",
                         defaultInputSource: "Input source behavior", followLastUsed: "Follow last used",
                         followLastUsedHint: "Remember the input source you last selected in this app or website.",
                         forceEnglishPunctuation: "Force English punctuation", remove: "Remove",
                         permissionHint: "Website detection and forced English punctuation require Accessibility permission.")
        }
    }
}
