import SwiftUI

extension TranslationStrings {
    var aiNotice: String {
        switch language {
        case .enUS: return "Add up to 20 API profiles and select which one translation uses. API Keys are stored in Keychain and excluded from export. Leave Key empty to retain the saved key for this profile."
        case .zhHans: return "最多可保存 20 个 AI API 配置，并选择翻译当前使用的配置。Key 存于钥匙串，不随设置导出；Key 留空会保留当前配置已保存的 Key。"
        case .zhTW: return "AI 翻譯會向設定的 HTTPS 介面傳送原文，可能產生費用。請填寫完整 /chat/completions 網址和模型 ID。Key 存於鑰匙圈，不隨設定匯出；留空只在網址不變時保留。修改後請先儲存。"
        case .zhHK: return "AI 翻譯會向設定的 HTTPS 介面傳送原文，可能產生費用。請填寫完整 /chat/completions 網址和模型 ID。Key 存於鑰匙圈，不隨設定輸出；留空只在網址不變時保留。修改後請先儲存。"
        case .ptBR: return "Envia texto ao endpoint HTTPS configurado e pode gerar custos. Informe a URL completa /chat/completions e o modelo. Chave no Chaves, fora da exportação. Campo vazio mantém a chave apenas para o mesmo endpoint. Salve antes de traduzir."
        case .tr: return "Metin yapılandırılan HTTPS adresine gönderilir; ücret doğabilir. Tam /chat/completions adresini ve model kimliğini girin. Anahtar Anahtar Zinciri’ndedir, dışa aktarılmaz. Boş alan yalnız aynı adres için anahtarı korur. Önce kaydedin."
        case .ru: return "Текст отправляется на указанный HTTPS-адрес; возможна оплата. Укажите полный URL /chat/completions и ID модели. Ключ в Связке ключей, без экспорта. Пустое поле сохраняет ключ только для прежнего адреса. Сначала сохраните."
        case .es: return "Envía texto al endpoint HTTPS configurado y puede generar costes. Introduce la URL completa /chat/completions y el modelo. Clave en el Llavero, sin exportación. Déjala vacía para conservarla solo con la misma URL. Guarda antes de traducir."
        case .de: return "Text wird an den konfigurierten HTTPS-Endpunkt gesendet; Kosten möglich. Vollständige /chat/completions-URL und Modell-ID eingeben. Schlüssel im Schlüsselbund, nicht im Export. Leer behält den Schlüssel nur bei gleicher URL. Vorher sichern."
        case .fr: return "Le texte est envoyé au point HTTPS configuré ; frais possibles. Indiquez l’URL complète /chat/completions et le modèle. Clé dans le Trousseau, hors export. Vide conserve la clé seulement pour la même URL. Enregistrez avant de traduire."
        case .it: return "Invia testo all’endpoint HTTPS configurato; possibili costi. Inserisci URL completo /chat/completions e modello. Chiave nel Portachiavi, esclusa dall’esportazione. Vuoto mantiene la chiave solo per lo stesso URL. Salva prima di tradurre."
        case .ja: return "原文を設定した HTTPS API に送信し、料金が発生する場合があります。完全な /chat/completions URL とモデル ID を入力してください。キーはキーチェーンに保存し、書き出しません。空欄なら同じ URL のキーのみ保持します。翻訳前に保存してください。"
        case .ko: return "원문을 설정한 HTTPS API로 전송하며 비용이 발생할 수 있습니다. 전체 /chat/completions URL과 모델 ID를 입력하세요. 키는 키체인에 저장되며 내보내지 않습니다. 빈 키는 URL이 같을 때만 유지됩니다. 번역 전에 저장하세요."
        }
    }
}

struct AITranslationSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var profiles: [AITranslationProfile] = []
    @State private var selectedID = ""
    @State private var name = ""
    @State private var endpoint = AITranslation.defaultEndpoint
    @State private var model = AITranslation.defaultModel
    @State private var key = ""
    @State private var message = ""
    @State private var saved = false
    @State private var hasStoredKey = false
    var body: some View {
        Section {
            ForEach(profiles) { profile in
                Button { selectedID = profile.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).foregroundStyle(.primary)
                            Text(profile.model).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.id == selectedID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button { addProfile() } label: { Label("新增 AI API", systemImage: "plus") }
                    .disabled(profiles.count >= 20)
                Spacer()
                Button(role: .destructive) { removeProfile() } label: { Label("删除当前配置", systemImage: "trash") }
                    .disabled(profiles.count <= 1)
            }
            Divider()
            TextField("Name", text: $name)
            TextField("API URL · /chat/completions", text: $endpoint)
            TextField("Model ID", text: $model)
            SecureField("API Key", text: $key, prompt: Text(hasStoredKey ? "••••••••" : "API Key"))
            Text(TranslationStrings.current.aiNotice).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(TranslationStrings.current[.save]) { save() }
                if saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
        } header: { Text("AI · API") }
        .onAppear {
            do {
                let state = try AITranslationProfiles.load()
                profiles = state.profiles
                selectedID = state.selectedID
                loadSelected()
            } catch { message = error.localizedDescription }
        }
        .onChange(of: selectedID) { _, _ in loadSelected() }
        .onChange(of: name) { _, _ in saved = false }
        .onChange(of: endpoint) { _, _ in saved = false }
        .onChange(of: model) { _, _ in saved = false }
        .onChange(of: key) { _, value in if !value.isEmpty { saved = false } }
    }
    private func save() {
        do {
            let url = try AITranslation.endpoint(endpoint).absoluteString
            guard let index = profiles.firstIndex(where: { $0.id == selectedID }),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AITranslation.Failure.configuration }
            let secret = key.isEmpty ? profiles[index].key : key.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try AITranslation.request(endpoint: url, model: model, key: secret, text: "validation", source: "auto", target: "en")
            profiles[index] = .init(id: selectedID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    endpoint: url, model: model.trimmingCharacters(in: .whitespacesAndNewlines), key: secret)
            try AITranslationProfiles.save(profiles, selectedID: selectedID)
            TranslationService.shared.refreshAIProfiles()
            TranslationService.shared.cancel()
            key = ""
            hasStoredKey = !secret.isEmpty
            saved = true
            message = ""
        } catch { message = error.localizedDescription; saved = false }
    }

    private func loadSelected() {
        guard let profile = profiles.first(where: { $0.id == selectedID }) else { return }
        name = profile.name; endpoint = profile.endpoint; model = profile.model
        key = ""; hasStoredKey = !profile.key.isEmpty; saved = false; message = ""
    }

    private func addProfile() {
        guard profiles.count < 20 else { return }
        let profile = AITranslationProfile(id: UUID().uuidString, name: "AI API \(profiles.count + 1)",
            endpoint: AITranslation.defaultEndpoint, model: AITranslation.defaultModel, key: "")
        profiles.append(profile); selectedID = profile.id
    }

    private func removeProfile() {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        profiles.remove(at: index)
        selectedID = profiles[min(index, profiles.count - 1)].id
        do {
            try AITranslationProfiles.save(profiles, selectedID: selectedID)
            TranslationService.shared.refreshAIProfiles()
            message = ""
        }
        catch { message = error.localizedDescription }
    }
}
