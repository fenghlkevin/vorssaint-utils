// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon
import Combine
import Foundation

struct ManagedInputSource: Identifiable, Hashable {
    let id: String
    let sourceID: String
    let inputModeID: String?
    let name: String

    static var selectable: [ManagedInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        var seen = Set<String>()
        return list.compactMap { source in
            guard source.stringProperty(kTISPropertyInputSourceCategory)
                    == kTISCategoryKeyboardInputSource as String,
                  source.boolProperty(kTISPropertyInputSourceIsSelectCapable),
                  let sourceID = source.stringProperty(kTISPropertyInputSourceID) else { return nil }
            let modeID = source.stringProperty(kTISPropertyInputModeID)
            let persistentID = Self.persistentID(sourceID: sourceID, inputModeID: modeID)
            guard seen.insert(persistentID).inserted else { return nil }
            let name = source.stringProperty(kTISPropertyLocalizedName) ?? sourceID
            return ManagedInputSource(id: persistentID, sourceID: sourceID,
                                      inputModeID: modeID, name: name)
        }
    }

    static var current: ManagedInputSource? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let sourceID = source.stringProperty(kTISPropertyInputSourceID) else { return nil }
        let modeID = source.stringProperty(kTISPropertyInputModeID)
        return ManagedInputSource(id: persistentID(sourceID: sourceID, inputModeID: modeID),
                                  sourceID: sourceID, inputModeID: modeID,
                                  name: source.stringProperty(kTISPropertyLocalizedName) ?? sourceID)
    }

    @discardableResult
    static func select(persistentID: String) -> Bool {
        guard let candidate = selectable.first(where: { $0.id == persistentID }) else { return false }
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first(where: {
                  $0.stringProperty(kTISPropertyInputSourceID) == candidate.sourceID
                    && ($0.stringProperty(kTISPropertyInputModeID) ?? "") == (candidate.inputModeID ?? "")
              }) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    static func persistentID(sourceID: String, inputModeID: String?) -> String {
        guard let inputModeID, !inputModeID.isEmpty else { return sourceID }
        return "\(sourceID)::\(inputModeID)"
    }
}

private extension TISInputSource {
    func stringProperty(_ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? String
    }

    func boolProperty(_ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return false }
        return (Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? Bool) ?? false
    }
}

struct InputSourceAppRule: Codable, Hashable, Identifiable {
    var bundleID: String
    var appName: String
    var sourceID: String
    var forceEnglishPunctuation: Bool
    var id: String { bundleID }
}

struct InputSourceDomainRule: Codable, Hashable, Identifiable {
    var domain: String
    var sourceID: String
    var id: String { domain }
}

enum InputSourceRuleSupport {
    static let followLastUsedSourceID = "__follow_last_used__"

    static func isFollowLastUsed(_ sourceID: String) -> Bool {
        sourceID == followLastUsedSourceID
    }

    static func normalizedDomain(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let host = URL(string: text)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func matchingRule(for host: String, rules: [InputSourceDomainRule]) -> InputSourceDomainRule? {
        guard let normalized = normalizedDomain(host) else { return nil }
        return rules
            .filter { normalized == $0.domain || normalized.hasSuffix("." + $0.domain) }
            .max { $0.domain.count < $1.domain.count }
    }
}

extension Notification.Name {
    static let inputSourceAutomationRulesChanged = Notification.Name("InputSourceAutomationRulesChanged")
}

@MainActor
final class InputSourceRuleStore: ObservableObject {
    static let shared = InputSourceRuleStore()

    @Published private(set) var appRules: [InputSourceAppRule]
    @Published private(set) var domainRules: [InputSourceDomainRule]

    private init(defaults: UserDefaults = .standard) {
        appRules = Self.decode([InputSourceAppRule].self,
                               from: defaults.data(forKey: DefaultsKey.inputSourceAppRules)) ?? []
        domainRules = Self.decode([InputSourceDomainRule].self,
                                  from: defaults.data(forKey: DefaultsKey.inputSourceDomainRules)) ?? []
    }

    func setAppRule(bundleID: String, appName: String, sourceID: String) {
        let punctuation = appRules.first { $0.bundleID == bundleID }?.forceEnglishPunctuation ?? false
        appRules.removeAll { $0.bundleID == bundleID }
        appRules.append(InputSourceAppRule(bundleID: bundleID, appName: appName,
                                            sourceID: sourceID,
                                            forceEnglishPunctuation: punctuation))
        appRules.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        save()
    }

    func setPunctuation(bundleID: String, appName: String, enabled: Bool) {
        if let index = appRules.firstIndex(where: { $0.bundleID == bundleID }) {
            appRules[index].forceEnglishPunctuation = enabled
        } else {
            let fallback = ManagedInputSource.current?.id ?? ManagedInputSource.selectable.first?.id ?? ""
            appRules.append(InputSourceAppRule(bundleID: bundleID, appName: appName,
                                                sourceID: fallback,
                                                forceEnglishPunctuation: enabled))
        }
        save()
    }

    func removeAppRule(bundleID: String) {
        appRules.removeAll { $0.bundleID == bundleID }
        save()
    }

    func setDomainRule(domain rawDomain: String, sourceID: String) {
        guard let domain = InputSourceRuleSupport.normalizedDomain(rawDomain) else { return }
        domainRules.removeAll { $0.domain == domain }
        domainRules.append(InputSourceDomainRule(domain: domain, sourceID: sourceID))
        domainRules.sort { $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending }
        save()
    }

    func removeDomainRule(domain: String) {
        domainRules.removeAll { $0.domain == domain }
        save()
    }

    func rememberedSource(for context: String, defaults: UserDefaults = .standard) -> String? {
        defaults.dictionary(forKey: DefaultsKey.inputSourceLastUsedSources)?[context] as? String
    }

    func rememberSource(_ sourceID: String, for context: String,
                        defaults: UserDefaults = .standard) {
        guard !sourceID.isEmpty, !InputSourceRuleSupport.isFollowLastUsed(sourceID) else { return }
        var values = defaults.dictionary(forKey: DefaultsKey.inputSourceLastUsedSources) as? [String: String] ?? [:]
        values[context] = sourceID
        defaults.set(values, forKey: DefaultsKey.inputSourceLastUsedSources)
    }

    private func save(defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(appRules), forKey: DefaultsKey.inputSourceAppRules)
        defaults.set(try? JSONEncoder().encode(domainRules), forKey: DefaultsKey.inputSourceDomainRules)
        NotificationCenter.default.post(name: .inputSourceAutomationRulesChanged, object: nil)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
