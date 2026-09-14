// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import Translation
import UniformTypeIdentifiers

final class TranslationWindowController: NSObject, NSWindowDelegate {
    static let shared = TranslationWindowController()
    private var panel: NSPanel?
    private var translationKeyMonitor: Any?
    var isVisible: Bool { panel?.isVisible == true }
    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 550),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.title = TranslationStrings.current[.title]
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.minSize = NSSize(width: 720, height: 440)
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: TranslationView())
            panel.delegate = self
            panel.center()
            self.panel = panel
            translationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
                guard let panel, event.window === panel, panel.isKeyWindow,
                      (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                let service = TranslationService.shared
                let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
                if modifiers == .shift && (event.keyCode == 126 || event.keyCode == 125) {
                    if !event.isARepeat { service.cycleProvider(backwards: event.keyCode == 126) }
                    return nil
                }
                guard event.keyCode == 36 || event.keyCode == 76,
                      [NSEvent.ModifierFlags.shift, .command].contains(modifiers) else { return event }
                if !event.isARepeat && !service.busy && !service.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    service.translate()
                }
                return nil
            }
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func hide() { panel?.orderOut(nil) }
    func close() {
        panel?.close(); panel = nil
        if let monitor = translationKeyMonitor { NSEvent.removeMonitor(monitor); translationKeyMonitor = nil }
    }
    func windowWillClose(_ notification: Notification) { TranslationService.shared.cancel() }
}

struct TranslationSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var model = TranslationService.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage("translation.selection.enabled") private var selectionEnabled = false
    @AppStorage("translation.open.enabled") private var openEnabled = true
    @AppStorage("translation.capture.enabled") private var captureEnabled = false
    var body: some View {
        Form {
          Section {
            Button(TranslationStrings.current.settingsLabels.open) { model.show() }
            Text(TranslationStrings.current[.caption]).font(.caption).foregroundStyle(.secondary)
            TranslationProviderPicker(title: TranslationStrings.current.settingsLabels.service,
                                      selection: $model.provider)
            TranslationLanguagePicker(title: TranslationStrings.current[.source], selection: $model.source, automatic: true)
            TranslationLanguagePicker(title: TranslationStrings.current[.target], selection: $model.target, automatic: false)
          } header: { Text(TranslationStrings.current.settingsLabels.service) }
          .settingsSectionAnchor(.translation)
          AITranslationSettings()
          CodexTranslationSettings()
          Section {
            Toggle(TranslationStrings.current.settingsLabels.open, isOn: $openEnabled)
            ShortcutPreferenceRow(role: .translationOpen, isEnabled: openEnabled) { model.syncWithPreferences() }
          } header: { Text(TranslationStrings.current.settingsLabels.open) }
          Section {
            Toggle(TranslationStrings.current[.selection], isOn: $selectionEnabled)
            ShortcutPreferenceRow(role: .translationSelection, isEnabled: selectionEnabled) {
                TranslationService.shared.syncWithPreferences()
            }
            if !permissions.accessibility {
                Button(l10n.s.permissionOpenSettings) { permissions.requestAccessibility() }
            }
          } header: { Text(TranslationStrings.current[.selection]) }
          Section {
            Toggle(TranslationStrings.current[.capture], isOn: $captureEnabled)
            ShortcutPreferenceRow(role: .translationCapture, isEnabled: captureEnabled) {
                TranslationService.shared.syncWithPreferences()
            }
            if !permissions.screenRecording {
                Button(l10n.s.permissionOpenSettings) { permissions.requestScreenRecording() }
            }
          } header: { Text(TranslationStrings.current[.capture]) }
            if model.shortcutRegistrationFailed {
                Text(l10n.s.shortcutUnavailable).font(.caption).foregroundStyle(.orange)
            }
          Section {
            Text(TranslationStrings.current.localNotice).font(.caption).foregroundStyle(.secondary)
          } header: { Text(TranslationStrings.current.settingsLabels.privacy) }
        }
        .formStyle(.grouped)
        .onChange(of: openEnabled) { _, _ in model.syncWithPreferences() }
        .onChange(of: selectionEnabled) { _, _ in TranslationService.shared.syncWithPreferences() }
        .onChange(of: captureEnabled) { _, _ in TranslationService.shared.syncWithPreferences() }
    }
}

struct TranslationView: View {
    @ObservedObject private var model = TranslationService.shared
    @ObservedObject private var l10n = L10n.shared
    @FocusState private var editing: Bool
    @State private var detectedLanguage: String?
    @State private var detectedText = ""
    private var strings: TranslationStrings { .current }
    private var limit: Int { 20000 }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Spacer().frame(width: 64)
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 18)).foregroundStyle(Color.accentColor)
                Text(strings[.title]).font(.headline)
                Spacer(minLength: 16)
                TranslationProviderPicker(title: strings.settingsLabels.service, selection: $model.provider)
                    .labelsHidden().frame(maxWidth: 240).help(strings.settingsLabels.service + " · ⇧ ↑ / ⇧ ↓")
                Button {
                    TranslationWindowController.shared.hide()
                    (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
                } label: { Image(systemName: "gearshape").font(.system(size: 16)) }
                    .buttonStyle(.plain).help(l10n.language.rawValue.hasPrefix("zh") ? "设置" : "Settings")
            }
            Divider()
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    TranslationLanguagePicker(title: strings[.source], selection: $model.source, automatic: true)
                        .labelsHidden().fixedSize()
                    if model.source == "auto", detectedText == model.text, let detectedLanguage {
                        Label(Locale(identifier: l10n.language.rawValue)
                            .localizedString(forIdentifier: detectedLanguage) ?? detectedLanguage,
                              systemImage: "checkmark")
                            .font(.caption).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity)
                Button {
                    let from = model.source == "auto" ? (detectedText == model.text ? detectedLanguage : nil) : model.source
                    guard let from else { return }
                    let oldTarget = model.target
                    model.target = from
                    model.source = oldTarget
                } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(TranslationCompactButtonStyle())
                    .disabled(model.source == "auto" && (detectedText != model.text || detectedLanguage == nil))
                    .help(l10n.language.rawValue.hasPrefix("zh") ? "互换语言" : "Swap languages")
                TranslationLanguagePicker(title: strings[.target], selection: $model.target, automatic: false)
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }.controlSize(.large)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(l10n.language.rawValue.hasPrefix("zh") ? "原文" : "Original").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.paste(); editing = true } label: {
                            Label(strings[.paste], systemImage: "doc.on.clipboard")
                        }.labelStyle(.iconOnly).buttonStyle(.borderless).help(strings[.paste])
                        Button { model.captureText() } label: {
                            Image(systemName: "viewfinder").accessibilityLabel(strings[.capture])
                        }.buttonStyle(.borderless).help(strings[.capture])
                    }.padding(14)
                    TextEditor(text: $model.text)
                        .font(.system(size: 16)).scrollContentBackground(.hidden)
                        .padding(.horizontal, 12).padding(.bottom, 14)
                        .focused($editing).accessibilityLabel(strings[.source])
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(l10n.language.rawValue.hasPrefix("zh") ? "译文" : "Translation").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.result, forType: .string)
                        } label: {
                            Label(l10n.s.menuCopy, systemImage: "doc.on.doc")
                        }.labelStyle(.iconOnly).buttonStyle(.borderless).help(l10n.s.menuCopy).disabled(model.result.isEmpty)
                    }.padding(14)
                    if model.result.isEmpty && model.error.isEmpty {
                        VStack(spacing: 12) {
                            if model.busy { ProgressView().controlSize(.large) }
                            else {
                                Text(l10n.language.rawValue.hasPrefix("zh") ? "译文将在这里显示" : "Translation appears here").font(.callout)
                            }
                        }.foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(model.result).font(.system(size: 16))
                                .lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }.frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            }.frame(maxHeight: .infinity)
            if !model.error.isEmpty {
                Label(model.error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Circle().fill(!model.error.isEmpty ? Color.orange : model.result.isEmpty ? Color.secondary : Color.green)
                    .frame(width: 6, height: 6)
                Text(model.busy ? strings.progress(model.stage) : model.result.isEmpty
                     ? (l10n.language.rawValue.hasPrefix("zh") ? "等待翻译" : "Ready")
                     : (l10n.language.rawValue.hasPrefix("zh") ? "翻译完成" : "Completed"))
                    .font(.caption).foregroundStyle(.secondary)
                if !model.busy, let elapsed = model.elapsed { Text(String(format: "%.1fs", elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                Image(systemName: "info.circle").foregroundStyle(.secondary).help(model.provider == "codex" ? strings.codexNotice : model.isAIProvider ? strings.aiNotice : strings.localNotice)
                Text("·  \(model.text.count) / \(limit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.text.count > limit ? Color.red : Color.secondary)
                Spacer()
                if model.busy {
                    Button(l10n.s.mediaCancel) { model.cancel() }.controlSize(.large)
                } else {
                    Button { model.translate() } label: {
                        Label(strings[.translate] + "  ⇧ ↩", systemImage: "arrow.right").padding(.horizontal, 12)
                    }
                    .keyboardShortcut(.return, modifiers: .shift)
                    .buttonStyle(TranslationCompactButtonStyle(primary: true))
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.text.count > limit)
                }
            }
            if #available(macOS 15.0, *), let request = model.systemRequest {
                SystemTranslationTask(request: request).id(request.id).frame(width: 0, height: 0)
            }
        }
        .padding(16)
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { editing = true }
        .task(id: model.text) {
            let input = model.text
            detectedLanguage = nil
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  input.count <= limit else { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled else { return }
            detectedLanguage = TranslationLanguageDetection.systemSource(
                text: input, requested: "auto", supported: TranslationService.languages)
            detectedText = input
        }
        .onExitCommand { model.cancel(); TranslationWindowController.shared.hide() }
    }
}

private struct TranslationProviderPicker: View {
    let title: String
    @Binding var selection: String
    @ObservedObject private var service = TranslationService.shared
    var body: some View {
        Picker(title, selection: $selection) {
            Text(TranslationStrings.current[.system]).tag("system")
            ForEach(service.aiProfileOptions) { profile in
                Text(profile.name).tag(TranslationProviderSelection.ai(profile.id))
            }
            Text("Codex · CLI").tag("codex")
        }
        .pickerStyle(.menu).buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
    }
}

private struct TranslationLanguagePicker: View {
    let title: String
    @Binding var selection: String
    let automatic: Bool
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        Picker(title, selection: $selection) {
            if automatic { Text(TranslationStrings.current[.auto]).tag("auto") }
            ForEach(TranslationService.languages, id: \.self) { code in
                Text(Locale(identifier: l10n.language.rawValue).localizedString(forIdentifier: code) ?? code).tag(code)
            }
        }
        .pickerStyle(.menu).buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
    }
}

private struct TranslationCompactButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, primary ? 16 : 10).padding(.vertical, 9)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(primary ? Color.accentColor : Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(primary ? 0 : 0.12)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

@available(macOS 15.0, *)
private struct SystemTranslationTask: View {
    let request: TranslationService.SystemRequest
    var body: some View {
        Color.clear.translationTask(source: request.source.map(Locale.Language.init(identifier:)),
                                    target: Locale.Language(identifier: request.target)) { session in
            do {
                let response = try await session.translate(request.text)
                guard !Task.isCancelled else { return }
                await MainActor.run { TranslationService.shared.finish(id: request.id, text: response.targetText) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { TranslationService.shared.finish(id: request.id, error: error.localizedDescription) }
            }
        }
    }
}

private struct TranslationPluginSettings: View {
    let plugin: BobPluginPackage
    @Environment(\.dismiss) private var dismiss
    @State private var options: [String: String] = [:]
    @State private var hosts = ""
    @State private var error = ""
    private var strings: TranslationStrings { .current }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plugin.manifest.name).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(strings.notice).font(.caption).foregroundStyle(.secondary)
                    TextField(strings[.hosts], text: $hosts)
                    ForEach(plugin.manifest.options ?? []) { option in
                        let value = Binding(get: { options[option.id] ?? option.defaultValue ?? "" },
                                            set: { options[option.id] = $0 })
                        if option.type == "menu" {
                            Picker(option.title, selection: value) {
                                ForEach(option.menuValues ?? [], id: \.value) { item in Text(item.title).tag(item.value) }
                            }
                        } else if option.textConfig?.type == "visible" {
                            TextField(option.title, text: value)
                        } else { SecureField(option.title, text: value) }
                    }
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(strings[.remove], role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = strings[.remove] + ": " + plugin.manifest.name
                    alert.addButton(withTitle: L10n.shared.s.cutCancel)
                    alert.addButton(withTitle: strings[.remove])
                    if alert.runModal() == .alertSecondButtonReturn {
                        do { try TranslationService.shared.removeSelectedPlugin(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button(L10n.shared.s.cutCancel) { dismiss() }
                Button(strings[.save]) { save() }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 560, height: 460)
        .onAppear {
            do {
                let config = try TranslationCredentials.load(plugin.id)
                options = Dictionary(uniqueKeysWithValues: (plugin.manifest.options ?? []).map { option in
                    (option.id, config.options[option.id] ?? option.defaultValue ?? option.menuValues?.first?.value ?? "")
                })
                hosts = config.hosts.joined(separator: ", ")
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        let domains = hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard domains.count <= 16, domains.allSatisfy({
            $0.range(of: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil
                && $0.contains(".") && !$0.contains("..")
        }) else { error = "Invalid HTTPS hostname"; return }
        do {
            try TranslationCredentials.save(.init(options: options, hosts: domains), id: plugin.id)
            TranslationService.shared.cancel()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
