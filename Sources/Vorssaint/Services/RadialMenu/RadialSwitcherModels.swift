// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

struct RadialFavorite: Codable, Identifiable, Equatable {
    let bundleID: String
    var name: String
    var path: String
    var id: String { bundleID }

    static func read(_ url: URL) -> RadialFavorite? {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        return RadialFavorite(bundleID: id,
                              name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                                  ?? url.deletingPathExtension().lastPathComponent,
                              path: url.path)
    }

    var resolvedURL: URL? {
        let stored = URL(fileURLWithPath: path)
        if Bundle(url: stored)?.bundleIdentifier == bundleID { return stored }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

struct RadialAppAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var shortcut: String

    var usableShortcut: GlobalShortcut? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return GlobalShortcut(storageValue: shortcut)
    }
}

struct RadialActionProfile: Codable, Identifiable, Equatable {
    var bundleID: String
    var appName: String
    var actions: [RadialAppAction]
    var id: String { bundleID }
}

enum RadialSwitcherStorage {
    struct ItemStyle: Codable, Equatable {
        var name: String
        var color: String
    }

    static let colors = ["", "red", "orange", "yellow", "green", "mint", "teal",
                         "cyan", "blue", "indigo", "purple", "pink", "brown"]

    static func styles(_ defaults: UserDefaults = .standard) -> [String: ItemStyle] {
        guard let data = defaults.data(forKey: DefaultsKey.radialSwitcherStyles) else { return [:] }
        return (try? JSONDecoder().decode([String: ItemStyle].self, from: data)) ?? [:]
    }

    static func styleKey(for entry: RadialSwitcherService.Entry) -> String? {
        switch entry {
        case .window(let item):
            let app = NSRunningApplication(processIdentifier: item.pid)
            let launch = app?.launchDate?.timeIntervalSince1970 ?? 0
            return "window:\(app?.bundleIdentifier ?? ""):\(item.pid):\(launch):\(item.id)"
        case .tab(let tab):
            let app = NSRunningApplication(processIdentifier: tab.pid)
            let launch = app?.launchDate?.timeIntervalSince1970 ?? 0
            return "tab:\(app?.bundleIdentifier ?? ""):\(tab.pid):\(launch):\(tab.id)"
        default: return nil
        }
    }
    static func favorites(_ defaults: UserDefaults = .standard) -> [RadialFavorite] {
        guard let data = defaults.data(forKey: DefaultsKey.radialSwitcherFavorites) else { return [] }
        return (try? JSONDecoder().decode([RadialFavorite].self, from: data)) ?? []
    }

    static func actions(_ defaults: UserDefaults = .standard) -> [RadialActionProfile] {
        guard let data = defaults.data(forKey: DefaultsKey.radialSwitcherActionProfiles) else { return [] }
        return (try? JSONDecoder().decode([RadialActionProfile].self, from: data)) ?? []
    }

    static func appRules(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: DefaultsKey.radialSwitcherAppRules) as? [String: String] ?? [:]
    }
}

enum RadialSwitcherLayout {
    static let panelSize: CGFloat = 560
    static let wheelDiameter: CGFloat = 460
    static let ringRadius: CGFloat = 178
    static let deadZoneRadius: CGFloat = 108
}
