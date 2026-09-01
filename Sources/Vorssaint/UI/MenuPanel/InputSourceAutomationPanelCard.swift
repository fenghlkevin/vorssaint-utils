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
    private var app: NSRunningApplication? { service.activeApplication }
    private var appRule: InputSourceAppRule? {
        guard let bundleID = app?.bundleIdentifier else { return nil }
        return store.appRules.first { $0.bundleID == bundleID }
    }
    private var domainRule: InputSourceDomainRule? {
        service.activeDomain.flatMap {
            InputSourceRuleSupport.matchingRule(for: $0, rules: store.domainRules)
        }
    }

    var body: some View {
        PanelSection(.inputSourceAutomation, title: text.pageTitle,
                     collapsible: collapsible) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(text.enable, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        InputSourceAutomationService.shared.syncWithPreferences()
                    }

                if let app, let bundleID = app.bundleIdentifier {
                    ruleCard(title: app.localizedName ?? bundleID,
                             symbol: "app",
                             selection: appSourceBinding(app: app, bundleID: bundleID)) {
                        Toggle(text.forceEnglishPunctuation,
                               isOn: punctuationBinding(app: app, bundleID: bundleID))
                            .font(.system(size: 11.5))
                    }
                } else {
                    statusText(noContextText)
                }

                if let domain = service.activeDomain {
                    ruleCard(title: domain, symbol: "globe",
                             selection: domainSourceBinding(domain: domain)) {
                        EmptyView()
                    }
                } else if enabled {
                    statusText(browserHint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { service.refreshMenuContext() }
        .onReceive(NotificationCenter.default.publisher(for: .menuPanelWillShow)) { _ in
            service.refreshMenuContext()
        }
    }

    private func ruleCard<Content: View>(title: String, symbol: String,
                                         selection: Binding<String>,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            Picker(text.defaultInputSource, selection: selection) {
                Text(notConfiguredText).tag("")
                Label(text.followLastUsed, systemImage: "clock.arrow.circlepath")
                    .tag(InputSourceRuleSupport.followLastUsedSourceID)
                Divider()
                ForEach(sources) { source in Text(source.name).tag(source.id) }
            }
            .font(.system(size: 11.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.045)))
    }

    private func statusText(_ value: String) -> some View {
        Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appSourceBinding(app: NSRunningApplication, bundleID: String) -> Binding<String> {
        Binding { appRule?.sourceID ?? "" } set: { sourceID in
            guard !sourceID.isEmpty else { store.removeAppRule(bundleID: bundleID); return }
            enableIfNeeded()
            store.setAppRule(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                             sourceID: sourceID)
        }
    }

    private func punctuationBinding(app: NSRunningApplication, bundleID: String) -> Binding<Bool> {
        Binding { appRule?.forceEnglishPunctuation ?? false } set: { value in
            enableIfNeeded()
            store.setPunctuation(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                 enabled: value)
        }
    }

    private func domainSourceBinding(domain: String) -> Binding<String> {
        Binding { domainRule?.sourceID ?? "" } set: { sourceID in
            guard !sourceID.isEmpty else { store.removeDomainRule(domain: domain); return }
            enableIfNeeded()
            store.setDomainRule(domain: domain, sourceID: sourceID)
        }
    }

    private func enableIfNeeded() {
        if !enabled { enabled = true }
        service.syncWithPreferences()
    }

    private var notConfiguredText: String {
        l10n.language == .zhHans ? "未设置" :
            ([.zhTW, .zhHK].contains(l10n.language) ? "未設定" : "Not configured")
    }

    private var browserHint: String {
        l10n.language == .zhHans ? "切换到浏览器网站后，可在这里设置当前域名。" :
            ([.zhTW, .zhHK].contains(l10n.language) ? "切換到瀏覽器網站後，可在這裡設定目前網域。" :
                "Switch to a website in a supported browser to configure its domain.")
    }

    private var noContextText: String {
        l10n.language == .zhHans ? "切换到要设置的软件后重新打开菜单。" :
            ([.zhTW, .zhHK].contains(l10n.language) ? "切換到要設定的軟件後重新開啟選單。" :
                "Switch to the app you want to configure, then reopen the menu.")
    }
}
