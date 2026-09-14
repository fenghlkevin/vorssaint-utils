// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import NaturalLanguage
import Security

final class TranslationService: ObservableObject {
    static let shared = TranslationService()
    static let pluginsEnabled = false
    struct SystemRequest: Identifiable {
        let id: UUID
        let text: String
        let source: String?
        let target: String
    }
    @Published var text = "" { didSet { if text != oldValue { cancel() } } }
    static let languages = ["zh-Hans", "zh-Hant", "en", "pt", "es", "fr", "de", "it", "ja", "ko", "ru", "tr", "ar", "hi", "th", "vi", "nl", "uk"]
    @Published var source = "auto" { didSet { if source != oldValue { UserDefaults.standard.set(source, forKey: "translation.source"); cancel() } } }
    @Published var target = "zh-Hans" { didSet { if target != oldValue { UserDefaults.standard.set(target, forKey: "translation.target"); cancel() } } }
    @Published var provider = "system" { didSet { if provider != oldValue { UserDefaults.standard.set(provider, forKey: TranslationProviderSelection.key); cancel() } } }
    @Published private(set) var result = ""
    @Published private(set) var error = ""
    @Published private(set) var busy = false
    @Published private(set) var stage: TranslationProgressStage = .idle
    @Published private(set) var elapsed: TimeInterval?
    @Published private(set) var aiProfileOptions: [AITranslationProfileOption] = []
    @Published private(set) var plugins: [BobPluginPackage] = []
    @Published private(set) var systemRequest: SystemRequest?
    @Published private(set) var shortcutRegistrationFailed = false
    private let selectionKey = QuickToolHotkey(id: 40)
    private let openKey = QuickToolHotkey(id: 42)
    private let captureKey = QuickToolHotkey(id: 41)
    private var process: TranslationProcess?
    private var aiTask: Task<Void, Never>?
    private var localOpenMonitor: Any?
    private var generation = UUID()
    private var capture: ScreenshotSelectionController?
    private var loaded = false
    private var startedAt: ContinuousClock.Instant?

    private init() {
        let defaults = UserDefaults.standard
        let state = try? AITranslationProfiles.load(defaults: defaults)
        aiProfileOptions = (state?.profiles ?? []).map { .init(id: $0.id, name: $0.name, model: $0.model) }
        provider = TranslationProviderSelection.restored(from: defaults, aiIDs: aiProfileOptions.map(\.id))
        defaults.set(provider, forKey: TranslationProviderSelection.key)
        if let value = defaults.string(forKey: "translation.source"), value == "auto" || Self.languages.contains(value) { source = value }
        if let value = defaults.string(forKey: "translation.target"), Self.languages.contains(value) { target = value }
        selectionKey.onPress = { [weak self] in self?.readSelection() }
        openKey.onPress = { [weak self] in self?.show() }
        captureKey.onPress = { [weak self] in self?.captureText() }
    }
    var selectedPlugin: BobPluginPackage? { plugins.first { $0.id == provider } }
    var isAIProvider: Bool { TranslationProviderSelection.aiID(provider) != nil }
    var providerDisplayName: String {
        if provider == "system" { return TranslationStrings.current[.system] }
        if provider == "codex" { return "Codex · CLI" }
        guard let id = TranslationProviderSelection.aiID(provider) else { return provider }
        return aiProfileOptions.first(where: { $0.id == id })?.name ?? "AI · API"
    }
    func cycleProvider(backwards: Bool) {
        provider = TranslationProviderSelection.next(after: provider, backwards: backwards,
                                                     aiIDs: aiProfileOptions.map(\.id))
    }
    func refreshAIProfiles(preferredID: String? = nil) {
        guard let state = try? AITranslationProfiles.load() else { return }
        aiProfileOptions = state.profiles.map { .init(id: $0.id, name: $0.name, model: $0.model) }
        if let preferredID, aiProfileOptions.contains(where: { $0.id == preferredID }) {
            provider = TranslationProviderSelection.ai(preferredID)
        } else if let id = TranslationProviderSelection.aiID(provider),
                  !aiProfileOptions.contains(where: { $0.id == id }) {
            provider = "system"
        }
    }

    private func translateAcquiredText(_ value: String) {
        text = value
        show()
        translate()
    }
    func syncWithPreferences() {
        let enabled = AppFeature.translation.isAvailable
        let openOK = openKey.sync(enabled: enabled && UserDefaults.standard.bool(forKey: "translation.open.enabled"),
                                  shortcut: GlobalShortcutRole.translationOpen.savedShortcut)
        let selectionOK = selectionKey.sync(enabled: enabled && UserDefaults.standard.bool(forKey: "translation.selection.enabled"),
                                            shortcut: GlobalShortcutRole.translationSelection.savedShortcut)
        let captureOK = captureKey.sync(enabled: enabled && UserDefaults.standard.bool(forKey: "translation.capture.enabled"),
                                        shortcut: GlobalShortcutRole.translationCapture.savedShortcut)
        shortcutRegistrationFailed = !openOK || !selectionOK || !captureOK
        if let monitor = localOpenMonitor { NSEvent.removeMonitor(monitor); localOpenMonitor = nil }
        if enabled && UserDefaults.standard.bool(forKey: "translation.open.enabled") {
            localOpenMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard !event.isARepeat, let cgEvent = event.cgEvent,
                      GlobalShortcutRole.translationOpen.savedShortcut.matches(event: cgEvent) else { return event }
                self?.show()
                return nil
            }
        }
        if !enabled { suspend(); TranslationWindowController.shared.close() }
    }
    func suspend() {
        cancel()
        capture?.cancel(); capture = nil
        selectionKey.unregister(); captureKey.unregister()
        openKey.unregister()
        if let monitor = localOpenMonitor { NSEvent.removeMonitor(monitor); localOpenMonitor = nil }
    }
    func show() {
        guard AppFeature.translation.isAvailable else { return }
        if Self.pluginsEnabled { loadPlugins() }
        TranslationWindowController.shared.show()
    }
    func paste() {
        guard AppFeature.translation.isAvailable else { return }
        if let value = NSPasteboard.general.string(forType: .string), value.count <= 20_000 {
            text = value
        } else { report("emptyInput / maximum 20000 characters") }
        show()
    }
    func readSelection() {
        guard AppFeature.translation.isAvailable else { return }
        cancel()
        let id = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let value = CommandBarSelectionReader.readSelectedText()
            DispatchQueue.main.async {
                guard id == self.generation, AppFeature.translation.isAvailable else { return }
                if value.isEmpty { self.report("No selection / Accessibility permission required. Use clipboard or screenshot.") }
                else { self.translateAcquiredText(value); return }
                self.show()
            }
        }
    }
    func captureText() {
        guard AppFeature.translation.isAvailable, capture == nil,
              !ScreenshotSelectionController.isSessionOnScreen else { return }
        guard Permissions.shared.screenRecording else { Permissions.shared.requestScreenRecording(); return }
        cancel()
        let id = generation
        let restoreWindowOnCancel = TranslationWindowController.shared.isVisible
        TranslationWindowController.shared.hide()
        let controller = ScreenshotSelectionController(freeze: true, includePointer: false,
            showLastRegion: false, purpose: TranslationStrings.current[.capture],
            requiresDraggedRegion: true, editsSelectedImage: false)
        capture = controller
        controller.begin { [weak self] outcome in
            guard let self else { return }
            self.capture = nil
            guard id == self.generation, AppFeature.translation.isAvailable else { return }
            switch outcome {
            case .captured(let capture):
                self.busy = true
                self.stage = .recognizing
                self.show()
                let fallbackLanguages = MediaSupport.recognitionLanguages(for: L10n.shared.language.rawValue)
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = ScreenTextService.outcome(for: capture.image, detectQRCodes: false,
                        removeLineBreaks: false, fallbackLanguages: fallbackLanguages)
                    DispatchQueue.main.async {
                        guard id == self.generation, AppFeature.translation.isAvailable else { return }
                        self.busy = false
                        if case .text(let text) = outcome, text.count <= 20_000 { self.translateAcquiredText(text) }
                        else { self.report("OCR: no text / maximum 20000 characters") }
                    }
                }
            case .cancelled:
                if restoreWindowOnCancel { self.show() }
            default: self.report("captureFailed"); self.show()
            }
        }
    }
    func cancel() {
        generation = UUID()
        process?.cancel(); process = nil
        aiTask?.cancel(); aiTask = nil
        systemRequest = nil
        busy = false
        stage = .idle
        startedAt = nil
        result = ""
        error = ""
    }
    func translate() {
        guard AppFeature.translation.isAvailable else { return }
        cancel()
        result = ""; error = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 20_000 else {
            report("emptyInput / maximum 20000 characters"); return
        }
        busy = true
        stage = provider == "system" ? .generating : .connecting
        startedAt = .now
        elapsed = nil
        let id = generation
        if provider == "system" {
            if #available(macOS 15.0, *) {
                systemRequest = SystemRequest(id: id, text: text,
                    source: TranslationLanguageDetection.systemSource(text: text, requested: source,
                                                                      supported: Self.languages), target: target)
            } else { report("Apple Translation requires macOS 15+") }
            return
        }
        if provider == "codex" {
            let runner = TranslationProcess()
            process = runner
            let path = UserDefaults.standard.string(forKey: CodexTranslation.pathKey) ?? ""
            let model = UserDefaults.standard.string(forKey: CodexTranslation.modelKey) ?? ""
            let effort = UserDefaults.standard.string(forKey: CodexTranslation.effortKey) ?? ""
            let speed = UserDefaults.standard.string(forKey: CodexTranslation.speedKey) ?? ""
            let input = text, from = source, to = target
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try CodexTranslation.run(runner: runner, path: path, model: model, text: input, source: from, target: to, effort: effort, speed: speed) { partial in
                    DispatchQueue.main.async {
                        guard id == self.generation else { return }
                        self.stage = .generating; self.result = partial
                    }
                } }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let text): self.finish(id: id, text: text)
                    case .failure(let error):
                        self.finish(id: id, error: TranslationStrings.current.codexFailure + " [\((error as? CodexTranslation.Failure)?.rawValue ?? "request")]")
                    }
                }
            }
            return
        }
        if let profileID = TranslationProviderSelection.aiID(provider) {
            do {
                let profile = try AITranslationProfiles.profile(id: profileID)
                let request = try AITranslation.request(endpoint: profile.endpoint,
                    model: profile.model, key: profile.key,
                    text: text, source: source, target: target)
                aiTask = Task { @MainActor in
                    do {
                        let value = try await AITranslation.send(request) { partial in
                            Task { @MainActor in
                                guard id == self.generation else { return }
                                self.stage = .generating; self.result = partial
                            }
                        }
                        guard !Task.isCancelled else { return }
                        self.finish(id: id, text: value)
                    } catch {
                        guard !Task.isCancelled else { return }
                        let message = (error as? AITranslation.Failure)?.localizedDescription
                            ?? "AI network error (\((error as NSError).code))"
                        self.finish(id: id, error: message)
                    }
                }
            } catch { report(error.localizedDescription) }
            return
        }
        guard Self.pluginsEnabled, let plugin = selectedPlugin else { report("Provider unavailable"); return }
        do {
            var configuration = try TranslationCredentials.load(plugin.id)
            for option in plugin.manifest.options ?? [] where configuration.options[option.id] == nil {
                configuration.options[option.id] = option.defaultValue ?? option.menuValues?.first?.value ?? ""
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let detected = recognizer.dominantLanguage?.rawValue ?? "en"
            let request = BobTranslationRequest(package: plugin, options: configuration.options,
                hosts: configuration.hosts, text: text, from: source, to: target,
                detectFrom: source == "auto" ? detected : source)
            let data = try JSONEncoder().encode(request)
            guard let executable = Bundle.main.executableURL else { throw TranslationFailure.storage }
            let runner = TranslationProcess()
            process = runner
            DispatchQueue.global(qos: .userInitiated).async {
                let response: Result<String, Error> = Result {
                    let data = try runner.run(executable: executable, arguments: ["--translation-plugin-worker"],
                                              input: data, timeout: 40, limit: 1_000_000)
                    return try Self.pluginText(data)
                }
                DispatchQueue.main.async {
                    switch response {
                    case .success(let text): self.finish(id: id, text: text)
                    case .failure(let error): self.finish(id: id, error: error.localizedDescription)
                    }
                }
            }
        } catch { report(error.localizedDescription) }
    }
    func finish(id: UUID, text: String = "", error: String = "") {
        guard id == generation, AppFeature.translation.isAvailable else { return }
        busy = false; systemRequest = nil; process = nil; aiTask = nil
        stage = .idle
        if let startedAt { elapsed = Double(startedAt.duration(to: .now).components.attoseconds) / 1e18 + Double(startedAt.duration(to: .now).components.seconds) }
        startedAt = nil
        self.result = text
        self.error = error
    }
    func report(_ message: String) { cancel(); error = message }

    static func pluginText(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslationFailure.invalidResult }
        if let error = object["error"] as? [String: Any] {
            // Plugin-provided messages are untrusted and may include secrets; do not persist them.
            let message = String((error["message"] as? String ?? "Plugin error").prefix(300))
            throw NSError(domain: "BobPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let result = object["result"] as? [String: Any] else { throw TranslationFailure.invalidResult }
        let paragraphs = result["toParagraphs"] as? [String] ?? []
        var text = paragraphs.joined(separator: "\n\n")
        if let dictionary = result["toDict"] as? [String: Any] {
            var lines: [String] = []
            if let word = dictionary["word"] as? String { lines.append(word) }
            for part in dictionary["parts"] as? [[String: Any]] ?? [] {
                lines.append((part["part"] as? String ?? "") + " " + (part["means"] as? [String] ?? []).joined(separator: "; "))
            }
            if !lines.isEmpty { text += (text.isEmpty ? "" : "\n\n") + lines.joined(separator: "\n") }
        }
        guard !text.isEmpty, text.utf8.count <= 500_000 else { throw TranslationFailure.invalidResult }
        return text
    }
    private var pluginDirectory: URL? { PrivateFileStore.containerURL?.appendingPathComponent("TranslationPlugins") }
    private func loadPlugins() {
        guard !loaded else { return }
        loaded = true
        guard let directory = pluginDirectory else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        plugins = urls.prefix(64).compactMap { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
            guard url.pathExtension == "json", size <= 10_000_000,
                  let data = try? Data(contentsOf: url), let plugin = try? JSONDecoder().decode(BobPluginPackage.self, from: data),
                  (try? plugin.validate()) != nil else { return nil }
            return plugin
        }.sorted { $0.manifest.name < $1.manifest.name }
    }
    func install(_ plugin: BobPluginPackage) throws {
        guard Self.pluginsEnabled else { throw TranslationFailure.storage }
        try plugin.validate()
        guard AppFeature.translation.isAvailable, let directory = pluginDirectory, PrivateFileStore.createDirectory(at: directory),
              !plugins.contains(where: { $0.id == plugin.id }), plugins.count < 64,
              PrivateFileStore.write(try JSONEncoder().encode(plugin), to: directory.appendingPathComponent(plugin.id + ".json"))
        else { throw TranslationFailure.storage }
        plugins.append(plugin)
        provider = plugin.id
    }
    func removeSelectedPlugin() throws {
        guard let plugin = selectedPlugin, let directory = pluginDirectory else { return }
        cancel()
        try FileManager.default.trashItem(at: directory.appendingPathComponent(plugin.id + ".json"), resultingItemURL: nil)
        plugins.removeAll { $0.id == plugin.id }
        provider = "system"
        try TranslationCredentials.remove(plugin.id)
    }
}
