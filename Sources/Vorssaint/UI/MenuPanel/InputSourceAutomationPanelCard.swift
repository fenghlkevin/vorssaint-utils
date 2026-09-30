// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct InputSourceAutomationPanelCard: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = InputSourceAutomationService.shared
    @ObservedObject private var store = InputSourceRuleStore.shared
    @AppStorage(DefaultsKey.inputSourceAutomationEnabled) private var enabled = false
    let collapsible: Bool

    private var text: InputSourceAutomationStrings { .current(l10n.language) }
    private var sources: [ManagedInputSource] { ManagedInputSource.selectable }
    private var app: NSRunningApplication? { service.menuApplication }
    private var currentAppRule: InputSourceAppRule? {
        guard let bundleID = app?.bundleIdentifier else { return nil }
        return store.appRules.first { $0.bundleID == bundleID }
    }
    private var domainRule: InputSourceDomainRule? {
        service.menuDomain.flatMap {
            InputSourceRuleSupport.matchingRule(for: $0, rules: store.domainRules)
        }
    }

    var body: some View {
        PanelSection(.inputSourceAutomation, title: text.pageTitle,
                     collapsible: collapsible) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                    Text(enabled ? enabledText : disabledText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Toggle(text.enable, isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: enabled) { _, _ in
                            InputSourceAutomationService.shared.syncWithPreferences()
                        }
                }

                if let rule = currentAppRule {
                    appRuleRow(rule)
                } else {
                    contextHint
                }

                if let domain = service.menuDomain {
                    domainRuleRow(domain)
                }

                if !store.appRules.isEmpty || !store.domainRules.isEmpty {
                    Divider().opacity(0.7)
                    savedRulesSummary
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { service.refreshMenuContext() }
        .onReceive(NotificationCenter.default.publisher(for: .menuPanelWillShow)) { _ in
            service.refreshMenuContext()
        }
    }

    private func appRuleRow(_ rule: InputSourceAppRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appIcon(bundleID: rule.bundleID)
                    .resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.appName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(text.appRuleLabel).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                removeButton { store.removeAppRule(bundleID: rule.bundleID) }
            }
            sourcePicker(selection: appSourceBinding(rule))
            Toggle(text.forceEnglishPunctuation,
                   isOn: punctuationBinding(rule))
                .font(.system(size: 10.5))
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .ruleSurface()
    }

    private func domainRuleRow(_ domain: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(domain).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(text.websiteRuleLabel).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if let domainRule {
                    removeButton { store.removeDomainRule(domain: domainRule.domain) }
                }
            }
            sourcePicker(selection: domainSourceBinding(domain: domain))
        }
        .ruleSurface()
    }

    @ViewBuilder
    private var contextHint: some View {
        if let app {
            HStack(spacing: 8) {
                appIcon(bundleID: app.bundleIdentifier ?? "")
                    .resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.localizedName ?? app.bundleIdentifier ?? text.currentApp)
                        .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text(text.noRuleForApp)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let bundleID = app.bundleIdentifier {
                    Button {
                        guard let sourceID = ManagedInputSource.current?.id ?? sources.first?.id else { return }
                        enableIfNeeded()
                        store.setAppRule(bundleID: bundleID,
                                         appName: app.localizedName ?? bundleID,
                                         sourceID: sourceID)
                    } label: {
                        Label(text.addRule, systemImage: "plus")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        } else {
            statusText(noContextText)
        }
    }

    private var savedRulesSummary: some View {
        HStack(spacing: 5) {
            Image(systemName: "list.bullet").font(.system(size: 9, weight: .semibold))
            Text(savedRulesText(apps: store.appRules.count, websites: store.domainRules.count))
                .font(.system(size: 9.5))
            Spacer(minLength: 4)
        }
        .foregroundStyle(.tertiary)
    }

    private func sourcePicker(selection: Binding<String>) -> some View {
        Picker(text.defaultInputSource, selection: selection) {
            Text(notConfiguredText).tag("")
            Label(text.followLastUsed, systemImage: "clock.arrow.circlepath")
                .tag(InputSourceRuleSupport.followLastUsedSourceID)
            Divider()
            ForEach(sources) { source in Text(source.name).tag(source.id) }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text.remove)
    }

    private func statusText(_ value: String) -> some View {
        Text(value).font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appIcon(bundleID: String) -> Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "app")
    }

    private func appSourceBinding(_ rule: InputSourceAppRule) -> Binding<String> {
        Binding { rule.sourceID } set: { sourceID in
            guard !sourceID.isEmpty else { store.removeAppRule(bundleID: rule.bundleID); return }
            enableIfNeeded()
            store.setAppRule(bundleID: rule.bundleID, appName: rule.appName, sourceID: sourceID)
        }
    }

    private func punctuationBinding(_ rule: InputSourceAppRule) -> Binding<Bool> {
        Binding { rule.forceEnglishPunctuation } set: { value in
            store.setPunctuation(bundleID: rule.bundleID, appName: rule.appName, enabled: value)
        }
    }

    private func domainSourceBinding(domain: String) -> Binding<String> {
        Binding { domainRule?.sourceID ?? "" } set: { sourceID in
            guard !sourceID.isEmpty else {
                if let domainRule { store.removeDomainRule(domain: domainRule.domain) }
                return
            }
            enableIfNeeded()
            store.setDomainRule(domain: domain, sourceID: sourceID)
        }
    }

    private func enableIfNeeded() {
        if !enabled { enabled = true }
        service.syncWithPreferences()
    }

    private var notConfiguredText: String {
        l10n.language == .zhHans ? "选择输入法" :
            ([.zhTW, .zhHK].contains(l10n.language) ? "選擇輸入法" : "Choose input source")
    }

    private var enabledText: String {
        l10n.language == .zhHans ? "自动切换已开启" :
            ([.zhTW, .zhHK].contains(l10n.language) ? "自動切換已開啟" : "Automatic switching is on")
    }

    private var disabledText: String {
        l10n.language == .zhHans ? "自动切换已关闭" :
            ([.zhTW, .zhHK].contains(l10n.language) ? "自動切換已關閉" : "Automatic switching is off")
    }

    private var noContextText: String {
        l10n.language == .zhHans ? "无法识别当前程序，请切换后重新打开菜单。" :
            ([.zhTW, .zhHK].contains(l10n.language) ? "無法識別目前程式，請切換後重新開啟選單。" :
                "Current app unavailable. Switch apps and reopen this menu.")
    }

    private func savedRulesText(apps: Int, websites: Int) -> String {
        if l10n.language == .zhHans { return "已保存规则：\(apps) 个软件 · \(websites) 个网站" }
        if [.zhTW, .zhHK].contains(l10n.language) { return "已儲存規則：\(apps) 個軟件 · \(websites) 個網站" }
        return "Saved rules: \(apps) apps · \(websites) websites"
    }
}

private extension View {
    func ruleSurface() -> some View {
        self.padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1))
    }
}
