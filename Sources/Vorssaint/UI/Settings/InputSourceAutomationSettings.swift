// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InputSourceAutomationSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var store = InputSourceRuleStore.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.inputSourceAutomationEnabled) private var enabled = false

    private var text: InputSourceAutomationStrings { .current(l10n.language) }
    private var sources: [ManagedInputSource] { ManagedInputSource.selectable }

    var body: some View {
        Form {
            Section(text.pageTitle) {
                Toggle(text.enable, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in
                        InputSourceAutomationService.shared.syncWithPreferences()
                    }
                Text(text.description).font(.caption).foregroundStyle(.secondary)
                if enabled, !permissions.accessibility {
                    Button {
                        permissions.requestAccessibility()
                        permissions.openAccessibilitySettings()
                    } label: {
                        Label(text.permissionHint, systemImage: "accessibility")
                    }
                }
            }

            Section {
                if store.appRules.isEmpty {
                    Text(text.noAppRules).foregroundStyle(.secondary)
                }
                ForEach(store.appRules) { rule in
                    HStack(spacing: 12) {
                        Image(nsImage: appIcon(bundleID: rule.bundleID))
                            .resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.appName).fontWeight(.semibold).lineLimit(1)
                            Text(rule.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                        sourcePicker(selection: appSourceBinding(rule))
                        HStack(spacing: 7) {
                            Text(text.forceEnglishPunctuation).font(.callout).lineLimit(1)
                            Toggle("", isOn: punctuationBinding(rule)).labelsHidden()
                        }
                        Button(role: .destructive) { store.removeAppRule(bundleID: rule.bundleID) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain).help(text.remove)
                    }
                    .padding(.vertical, 5)
                }
            } header: {
                HStack {
                    Text(text.appRules)
                    Spacer()
                    Button(action: chooseApp) {
                        Label(text.addApp, systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .textCase(nil)
                }
            }

            Section(text.websiteRules) {
                if store.domainRules.isEmpty {
                    Text(text.noWebsiteRules).foregroundStyle(.secondary)
                }
                ForEach(store.domainRules) { rule in
                    HStack(spacing: 12) {
                        Image(systemName: "globe").font(.title2).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                        Text(rule.domain).fontWeight(.semibold).lineLimit(1)
                            .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                        sourcePicker(selection: domainSourceBinding(rule))
                        Button(role: .destructive) { store.removeDomainRule(domain: rule.domain) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain).help(text.remove)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func sourcePicker(selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            Label(text.followLastUsed, systemImage: "clock.arrow.circlepath")
                .tag(InputSourceRuleSupport.followLastUsedSourceID)
            Divider()
            ForEach(sources) { source in Text(source.name).tag(source.id) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 190)
        .help(selection.wrappedValue == InputSourceRuleSupport.followLastUsedSourceID
              ? text.followLastUsedHint : text.defaultInputSource)
    }

    private func appIcon(bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = text.chooseApp
        panel.prompt = text.addApp
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              let sourceID = ManagedInputSource.current?.id ?? sources.first?.id else { return }
        let displayName = FileManager.default.displayName(atPath: url.path)
        let appName = (displayName as NSString).deletingPathExtension
        store.setAppRule(bundleID: bundleID, appName: appName, sourceID: sourceID)
    }

    private func appSourceBinding(_ rule: InputSourceAppRule) -> Binding<String> {
        Binding { rule.sourceID } set: {
            store.setAppRule(bundleID: rule.bundleID, appName: rule.appName, sourceID: $0)
        }
    }

    private func punctuationBinding(_ rule: InputSourceAppRule) -> Binding<Bool> {
        Binding { rule.forceEnglishPunctuation } set: {
            store.setPunctuation(bundleID: rule.bundleID, appName: rule.appName, enabled: $0)
        }
    }

    private func domainSourceBinding(_ rule: InputSourceDomainRule) -> Binding<String> {
        Binding { rule.sourceID } set: { store.setDomainRule(domain: rule.domain, sourceID: $0) }
    }
}
