// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The rules behind offering the Mac's own Settings panes as rows. Pure, so
/// what counts as a pane and what a pane answers to are pinned by tests rather
/// than rediscovered against whatever macOS is installed.
enum CommandBarSystemSettingsSupport {
    /// The largest real pane on current macOS uses 157 distinct terms. Keeping
    /// all of them preserves searches near the end, such as display resolution,
    /// while still bounding the normalized index built for every keystroke.
    static let keywordLimit = 160

    /// Whether an extension is one of the panes System Settings shows.
    ///
    /// The folder holds every kind of system extension, most of which are
    /// thumbnailers, intents and widgets. A pane declares itself twice over:
    /// it carries the Settings attributes, and it says it answers to the
    /// `x-apple.systempreferences:` address. Both are required, because the
    /// address is the only way a row has of opening it.
    static func isOpenablePane(info: [String: Any]) -> Bool {
        guard let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
              let settings = attributes["SettingsExtensionAttributes"] as? [String: Any]
        else { return false }
        return settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true
    }

    /// What to call a pane. The display name macOS resolves is the one System
    /// Settings itself shows, rather than an internal bundle name; a bundle
    /// that declares none falls back to its own name, and finally to the file,
    /// which is never pretty but is never empty either.
    static func paneName(localizedDisplayName: String?,
                         displayName: String?,
                         bundleName: String?,
                         fileName: String) -> String {
        for candidate in [localizedDisplayName, displayName, bundleName] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return (fileName as NSString).deletingPathExtension
    }

    /// The words a pane answers to, out of the index Apple ships beside it.
    ///
    /// This is the part that IS translated: the pane names macOS resolves are
    /// English whatever the Mac speaks, but every pane carries a `.searchTerms`
    /// file per language holding the words its own settings are searched by.
    /// Reading those in the app's language is what lets "impresora" find
    /// Printers & Scanners on a Mac that only ever says "Printers & Scanners".
    /// The file groups its strings under one key per section of the pane, and
    /// the names of those keys are the pane's own business: Appearance calls
    /// its only one "Main", Displays ships six. So every top-level group is
    /// read, in name order, which is what makes the words the same on two Macs
    /// running the same macOS.
    static func keywords(fromSearchTerms terms: [String: Any],
                         limit: Int = keywordLimit) -> String {
        var seen = Set<String>()
        var words: [String] = []
        for key in terms.keys.sorted() {
            guard let group = terms[key] as? [String: Any],
                  let strings = group["localizableStrings"] as? [[String: Any]]
            else { continue }
            for entry in strings {
                // The section title first: it is the phrase a person is
                // likeliest to type, and the index words are its synonyms.
                let title = entry["title"] as? String ?? ""
                let index = entry["index"] as? String ?? ""
                for word in ([title] + index.split(separator: ",").map(String.init)) {
                    let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty, clean.count <= 40,
                          seen.insert(clean.lowercased()).inserted else { continue }
                    words.append(clean)
                    if words.count >= limit { return words.joined(separator: " ") }
                }
            }
        }
        return words.joined(separator: " ")
    }

    struct Detail: Equatable {
        let section: String
        let title: String
        let keywords: String
    }

    /// Keep each indexed control searchable and visible as its own result.
    static func details(fromSearchTerms terms: [String: Any]) -> [Detail] {
        var result: [Detail] = []
        var seen = Set<String>()
        for section in terms.keys.sorted() {
            guard let group = terms[section] as? [String: Any],
                  let entries = group["localizableStrings"] as? [[String: Any]] else { continue }
            for entry in entries {
                let title = (entry["title"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, seen.insert(section + "\n" + title).inserted else { continue }
                result.append(Detail(section: section, title: title,
                                     keywords: (entry["index"] as? String ?? "") + " " + aliases(for: section)))
            }
        }
        return result
    }

    /// Apple's index sometimes omits the short label shown in the privacy list.
    private static func aliases(for section: String) -> String {
        switch section {
        case "Privacy_ScreenCapture": return "屏幕录制 屏幕与系统音频录制 螢幕錄製 screen recording"
        case "Privacy_AllFiles": return "完全磁盘访问权限 完整磁碟存取權 full disk access"
        case "Privacy_Accessibility": return "辅助功能 輔助使用 accessibility"
        case "Privacy_ListenEvent": return "输入监控 輸入監控 input monitoring"
        default: return ""
        }
    }

    /// Generate once while loading the catalog, never on each keystroke.
    /// Romanize aliases separately so their initials remain independently searchable.
    static func searchableKeywords(title: String, keywords: String) -> String {
        var seen = Set<String>()
        let phrases = [title] + keywords.split {
            $0.isWhitespace || $0 == "," || $0 == "，"
        }.map(String.init)
        let pinyin = phrases.compactMap { phrase -> String? in
            guard seen.insert(phrase).inserted else { return nil }
            let value = CommandBarSearch.indexedPinyinKeywords(phrase)
            return value.isEmpty ? nil : value
        }
        return ([keywords] + pinyin).joined(separator: " ")
    }

    /// A title's romanization has the same relevance as its visible spelling,
    /// rather than competing with the broad synonyms of every child setting.
    static func rankingTitle(_ title: String) -> String {
        let pinyin = CommandBarSearch.indexedPinyinKeywords(title)
        return pinyin.isEmpty ? title : title + " " + pinyin
    }

    /// The old preference pane a Settings pane grew out of, when it says so.
    /// Several panes keep their translated index words only in that older
    /// bundle, and it is named right there in the newer one.
    static func legacyPaneName(info: [String: Any]) -> String? {
        guard let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
              let settings = attributes["SettingsExtensionAttributes"] as? [String: Any],
              let name = settings["legacyPrefPaneBundleName"] as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    /// The folder Apple files a language's resources under. Their names are
    /// not the language tags the app uses, and the two Chinese variants are
    /// the pair that would silently fall back to English if this guessed.
    static func resourceFolder(for language: AppLanguage) -> String {
        switch language {
        case .enUS: return "en"
        case .ptBR: return "pt_BR"
        case .tr: return "tr"
        case .ru: return "ru"
        case .es: return "es"
        case .de: return "de"
        case .fr: return "fr"
        case .it: return "it"
        case .ja: return "ja"
        case .ko: return "ko"
        case .zhHans: return "zh_CN"
        case .zhTW: return "zh_TW"
        case .zhHK: return "zh_HK"
        }
    }
}
