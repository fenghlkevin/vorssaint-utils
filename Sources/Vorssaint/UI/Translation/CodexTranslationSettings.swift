// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct CodexTranslationSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(CodexTranslation.pathKey) private var path = ""
    @AppStorage(CodexTranslation.modelKey) private var model = ""
    @AppStorage(CodexTranslation.effortKey) private var effort = ""
    @AppStorage(CodexTranslation.speedKey) private var speed = ""
    @State private var models: [CodexTranslation.Model] = []
    @State private var refresh = UUID()
    @State private var loading = false
    @State private var failed = false
    private var selected: CodexTranslation.Model? { models.first { $0.id == model } }
    private var strings: TranslationStrings { .current }
    var body: some View {
        Section {
            TextField("Codex CLI · /path/to/codex", text: $path)
            Picker(strings.codexOptions.model, selection: $model) {
                Text(strings.codexOptions.automatic).tag("")
                ForEach(models) { item in Text(item.display_name).tag(item.id) }
                if !model.isEmpty && selected == nil { Text(model).tag(model) }
            }
            Picker(strings.codexOptions.speed, selection: $speed) {
                Text(strings.codexOptions.standard).tag("")
                if selected?.supportsFast == true || speed == "fast" { Text(strings.codexOptions.fast).tag("fast") }
            }.disabled(loading || selected == nil)
            Picker(strings.codexOptions.effort, selection: $effort) {
                Text(strings.codexOptions.automatic).tag("")
                ForEach(selected?.efforts ?? [], id: \.self) { value in Text(strings.codexEffort(value)).tag(value) }
                if !effort.isEmpty && !(selected?.efforts.contains(effort) ?? false) { Text(strings.codexEffort(effort)).tag(effort) }
            }.disabled(loading || selected == nil)
            HStack {
                Button(strings.codexOptions.refresh) { refresh = UUID() }.disabled(loading)
                Button(strings.codexOptions.speedFirst) { prioritizeSpeed() }.disabled(loading || models.isEmpty)
                if loading { ProgressView().controlSize(.small) }
            }
            Text(strings.codexOptions.notice).font(.caption).foregroundStyle(.secondary)
            if failed { Text(strings.codexFailure).font(.caption).foregroundStyle(.orange) }
            Text(TranslationStrings.current.codexNotice).font(.caption).foregroundStyle(.secondary)
        } header: { Text("Codex · CLI") }
        .onChange(of: path) { _, _ in TranslationService.shared.cancel() }
        .onChange(of: model) { _, _ in effort = ""; speed = ""; TranslationService.shared.cancel() }
        .onChange(of: effort) { _, _ in TranslationService.shared.cancel() }
        .onChange(of: speed) { _, _ in TranslationService.shared.cancel() }
        .task(id: path + refresh.uuidString) {
            loading = true; failed = false; models = []
            do {
                try await Task.sleep(for: .milliseconds(350))
                let catalog = try await CodexTranslation.loadModels(path: path, refresh: true)
                guard !Task.isCancelled else { return }
                models = catalog
                if let selected {
                    if !selected.efforts.contains(effort) { effort = "" }
                    if !selected.supportsFast { speed = "" }
                }
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            loading = false
        }
    }
    private func prioritizeSpeed() {
        guard let preset = CodexTranslation.speedPreset(models) else { return }
        model = preset.model
        DispatchQueue.main.async { effort = preset.effort; speed = preset.speed }
    }
}
