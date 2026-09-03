// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

extension TranslationStrings {
    var localNotice: String {
        switch language {
        case .enUS: return "Apple translates on-device (macOS 15+). Language models may need to be downloaded first."
        case .zhHans: return "Apple 翻译在本机处理（需要 macOS 15+），首次使用可能需要下载语言模型。"
        case .zhTW: return "Apple 翻譯在本機處理（需要 macOS 15+），首次使用可能需要下載語言模型。"
        case .zhHK: return "Apple 翻譯在本機處理（需要 macOS 15+），首次使用可能需要下載語言模型。"
        case .ptBR: return "Apple traduz no dispositivo (macOS 15+). Pode ser necessário baixar modelos."
        case .tr: return "Apple aygıtta çevirir (macOS 15+). Dil modellerinin indirilmesi gerekebilir."
        case .ru: return "Apple переводит на устройстве (macOS 15+). Может потребоваться загрузка моделей."
        case .es: return "Apple traduce en el dispositivo (macOS 15+). Puede requerir descargar modelos."
        case .de: return "Apple übersetzt auf dem Gerät (macOS 15+). Sprachmodelle müssen ggf. geladen werden."
        case .fr: return "Apple traduit sur l’appareil (macOS 15+). Des modèles peuvent être téléchargés."
        case .it: return "Apple traduce sul dispositivo (macOS 15+). Potrebbe essere necessario scaricare modelli."
        case .ja: return "Apple は端末上で翻訳します（macOS 15以降）。初回は言語モデルのダウンロードが必要な場合があります。"
        case .ko: return "Apple은 기기에서 번역합니다(macOS 15 이상). 처음에는 언어 모델 다운로드가 필요할 수 있습니다."
        }
    }
}
extension TranslationStrings {
    var settingsLabels: (service: String, open: String, privacy: String) {
        switch language {
        case .enUS: return ("Translation service", "Open translator", "Privacy & network")
        case .zhHans: return ("翻译服务与语言", "打开翻译窗口", "隐私与网络")
        case .zhTW: return ("翻譯服務與語言", "開啟翻譯視窗", "隱私與網路")
        case .zhHK: return ("翻譯服務與語言", "開啟翻譯視窗", "私隱與網絡")
        case .ptBR: return ("Serviço e idiomas", "Abrir tradutor", "Privacidade e rede")
        case .tr: return ("Çeviri hizmeti ve diller", "Çeviriyi aç", "Gizlilik ve ağ")
        case .ru: return ("Сервис и языки", "Открыть переводчик", "Конфиденциальность и сеть")
        case .es: return ("Servicio e idiomas", "Abrir traductor", "Privacidad y red")
        case .de: return ("Übersetzungsdienst und Sprachen", "Übersetzer öffnen", "Datenschutz und Netzwerk")
        case .fr: return ("Service et langues", "Ouvrir le traducteur", "Confidentialité et réseau")
        case .it: return ("Servizio e lingue", "Apri traduttore", "Privacy e rete")
        case .ja: return ("翻訳サービスと言語", "翻訳ウインドウを開く", "プライバシーとネットワーク")
        case .ko: return ("번역 서비스 및 언어", "번역 창 열기", "개인정보 및 네트워크")
        }
    }
}



struct TranslationStrings {
    enum Key: Int, CaseIterable {
        case title, caption, system, plugins, importPlugin, hosts, selection, capture, paste, translate
        case source, target, auto, configure, save, remove, trust
    }
    let language: AppLanguage
    static var current: Self { Self(language: L10n.shared.language) }
    subscript(_ key: Key) -> String { values[key.rawValue] }
    private var values: [String] {
        switch language {
        case .enUS: return ["Translation", "Translate selected text, screenshots and clipboard text", "Apple · on-device (macOS 15+)", "Bob text plugins · experimental", "Import .bobplugin", "Allowed HTTPS hosts (comma-separated)", "Translate selection", "Screenshot translation", "Paste", "Translate", "Source", "Target", "Detect language", "Configure plugin", "Save", "Remove plugin", "Trust and import"]
        case .ptBR: return ["Tradução", "Traduza seleções, capturas e texto copiado", "Apple · no dispositivo (macOS 15+)", "Plugins de texto Bob · experimental", "Importar .bobplugin", "Hosts HTTPS permitidos (separados por vírgula)", "Traduzir seleção", "Traduzir captura", "Colar", "Traduzir", "Origem", "Destino", "Detectar idioma", "Configurar plugin", "Salvar", "Remover plugin", "Confiar e importar"]
        case .tr: return ["Çeviri", "Seçimi, ekran görüntülerini ve pano metnini çevirin", "Apple · aygıtta (macOS 15+)", "Bob metin eklentileri · deneysel", ".bobplugin içe aktar", "İzin verilen HTTPS sunucuları (virgülle)", "Seçimi çevir", "Ekran görüntüsünü çevir", "Yapıştır", "Çevir", "Kaynak", "Hedef", "Dili algıla", "Eklentiyi yapılandır", "Kaydet", "Eklentiyi kaldır", "Güven ve içe aktar"]
        case .ru: return ["Перевод", "Перевод выделения, снимков и текста буфера", "Apple · на устройстве (macOS 15+)", "Текстовые плагины Bob · эксперимент", "Импорт .bobplugin", "Разрешённые HTTPS-хосты (через запятую)", "Перевести выделение", "Перевести снимок", "Вставить", "Перевести", "Исходный", "Целевой", "Определить язык", "Настроить плагин", "Сохранить", "Удалить плагин", "Доверять и импортировать"]
        case .es: return ["Traducción", "Traduce selecciones, capturas y texto copiado", "Apple · en el dispositivo (macOS 15+)", "Plugins de texto Bob · experimental", "Importar .bobplugin", "Hosts HTTPS permitidos (separados por comas)", "Traducir selección", "Traducir captura", "Pegar", "Traducir", "Origen", "Destino", "Detectar idioma", "Configurar plugin", "Guardar", "Eliminar plugin", "Confiar e importar"]
        case .de: return ["Übersetzung", "Auswahl, Bildschirmfotos und Zwischenablage übersetzen", "Apple · auf dem Gerät (macOS 15+)", "Bob-Textplugins · experimentell", ".bobplugin importieren", "Erlaubte HTTPS-Hosts (kommagetrennt)", "Auswahl übersetzen", "Bildschirmfoto übersetzen", "Einfügen", "Übersetzen", "Ausgangssprache", "Zielsprache", "Sprache erkennen", "Plugin konfigurieren", "Sichern", "Plugin entfernen", "Vertrauen und importieren"]
        case .fr: return ["Traduction", "Traduire la sélection, les captures et le presse-papiers", "Apple · sur l’appareil (macOS 15+)", "Plugins texte Bob · expérimental", "Importer .bobplugin", "Hôtes HTTPS autorisés (séparés par des virgules)", "Traduire la sélection", "Traduire une capture", "Coller", "Traduire", "Source", "Cible", "Détecter la langue", "Configurer le plugin", "Enregistrer", "Supprimer le plugin", "Faire confiance et importer"]
        case .it: return ["Traduzione", "Traduci selezioni, schermate e testo copiato", "Apple · sul dispositivo (macOS 15+)", "Plugin di testo Bob · sperimentale", "Importa .bobplugin", "Host HTTPS consentiti (separati da virgole)", "Traduci selezione", "Traduci schermata", "Incolla", "Traduci", "Origine", "Destinazione", "Rileva lingua", "Configura plugin", "Salva", "Rimuovi plugin", "Considera attendibile e importa"]
        case .ja: return ["翻訳", "選択テキスト・スクリーンショット・クリップボードを翻訳", "Apple · デバイス上 (macOS 15+)", "Bob テキストプラグイン · 試験機能", ".bobplugin を読み込む", "許可する HTTPS ホスト（カンマ区切り）", "選択範囲を翻訳", "スクリーンショット翻訳", "ペースト", "翻訳", "原文の言語", "訳文の言語", "言語を検出", "プラグイン設定", "保存", "プラグインを削除", "信頼して読み込む"]
        case .ko: return ["번역", "선택 텍스트, 스크린샷 및 클립보드 번역", "Apple · 기기 내 (macOS 15+)", "Bob 텍스트 플러그인 · 실험적", ".bobplugin 가져오기", "허용 HTTPS 호스트 (쉼표로 구분)", "선택 영역 번역", "스크린샷 번역", "붙여넣기", "번역", "원본 언어", "대상 언어", "언어 감지", "플러그인 설정", "저장", "플러그인 제거", "신뢰하고 가져오기"]
        case .zhHans: return ["翻译", "翻译选中文字、截图和剪贴板文本", "Apple · 本地翻译（macOS 15+）", "Bob 文本插件 · 实验性", "导入 .bobplugin", "允许的 HTTPS 域名（逗号分隔）", "划词翻译", "截图翻译", "粘贴", "翻译", "源语言", "目标语言", "自动检测", "配置插件", "保存", "移除插件", "信任并导入"]
        case .zhTW: return ["翻譯", "翻譯選取文字、截圖和剪貼簿文字", "Apple · 本機翻譯（macOS 15+）", "Bob 文字外掛 · 實驗性", "匯入 .bobplugin", "允許的 HTTPS 網域（逗號分隔）", "選取文字翻譯", "截圖翻譯", "貼上", "翻譯", "來源語言", "目標語言", "自動偵測", "設定外掛", "儲存", "移除外掛", "信任並匯入"]
        case .zhHK: return ["翻譯", "翻譯所選文字、螢幕截圖和剪貼簿文字", "Apple · 本機翻譯（macOS 15+）", "Bob 文字外掛 · 實驗性", "輸入 .bobplugin", "允許的 HTTPS 網域（逗號分隔）", "所選文字翻譯", "螢幕截圖翻譯", "貼上", "翻譯", "來源語言", "目標語言", "自動偵測", "設定外掛", "儲存", "移除外掛", "信任並輸入"]
        }
    }
    var notice: String {
        switch language {
        case .zhHans: return "系统翻译在本机处理，首次可能下载语言模型。仅导入可信的 Bob 文本翻译插件：插件可向你批准的域名发送原文及配置（含密钥），可能产生服务费用。配置存于钥匙串。兼容层不支持流式网络、文件、语音、OCR 或内置 crypto-js；不保证所有插件可用。每次运行最长 40 秒。"
        case .zhTW, .zhHK: return "系統翻譯在本機處理，首次可能下載語言模型。只匯入可信的 Bob 文字翻譯外掛：外掛可向你批准的網域傳送原文和設定（含金鑰），可能產生費用。設定存於鑰匙圈。不支援串流網絡、檔案、語音、OCR 或內建 crypto-js；不保證所有外掛可用。每次最長 40 秒。"
        case .ptBR: return "A Apple traduz localmente; pode baixar modelos. Importe apenas plugins Bob de texto confiáveis: eles podem enviar texto e opções (incluindo chaves) aos hosts aprovados e gerar custos. Opções no Chaves. Sem streaming, arquivos, voz, OCR ou crypto-js integrado. Compatibilidade parcial; limite de 40 s."
        case .tr: return "Apple yerel çeviri yapar; model indirebilir. Yalnız güvenilir Bob metin eklentilerini içe aktarın: metin ve seçenekler (anahtarlar dahil) onaylı sunuculara gönderilebilir ve ücret doğabilir. Seçenekler Anahtar Zinciri’ndedir. Akış, dosya, ses, OCR ve yerleşik crypto-js yoktur. Kısmi uyumluluk; 40 sn sınırı."
        case .ru: return "Apple переводит локально; возможна загрузка моделей. Импортируйте только доверенные текстовые плагины Bob: текст и настройки (включая ключи) могут отправляться разрешённым хостам с оплатой услуг. Настройки в Связке ключей. Нет потоковой сети, файлов, речи, OCR и встроенного crypto-js. Частичная совместимость; лимит 40 с."
        case .es: return "Apple traduce localmente; puede descargar modelos. Importa solo plugins Bob de texto fiables: pueden enviar texto y opciones (incluidas claves) a los hosts autorizados y generar costes. Opciones en el Llavero. Sin streaming, archivos, voz, OCR ni crypto-js integrado. Compatibilidad parcial; límite de 40 s."
        case .de: return "Apple übersetzt lokal; Modelle werden ggf. geladen. Nur vertrauenswürdige Bob-Textplugins importieren: Text und Optionen (einschließlich Schlüssel) können an erlaubte Hosts gesendet werden und Kosten verursachen. Optionen im Schlüsselbund. Kein Streaming, Dateizugriff, Sprache, OCR oder eingebautes crypto-js. Teilkompatibel; maximal 40 s."
        case .fr: return "Apple traduit localement ; téléchargement de modèles possible. Importez seulement des plugins texte Bob fiables : texte et options (clés comprises) peuvent être envoyés aux hôtes autorisés et entraîner des frais. Options dans le Trousseau. Sans streaming, fichiers, voix, OCR ni crypto-js intégré. Compatibilité partielle ; limite de 40 s."
        case .it: return "Apple traduce localmente; può scaricare modelli. Importa solo plugin di testo Bob affidabili: testo e opzioni (chiavi incluse) possono essere inviati agli host autorizzati con possibili costi. Opzioni nel Portachiavi. Nessuno streaming, file, voce, OCR o crypto-js integrato. Compatibilità parziale; limite di 40 s."
        case .ja: return "Apple は端末上で翻訳し、必要に応じてモデルをダウンロードします。信頼できる Bob テキストプラグインのみ読み込んでください。原文と設定（キーを含む）が許可ホストへ送信され、料金が発生する場合があります。設定はキーチェーンに保存します。ストリーミング・ファイル・音声・OCR・内蔵 crypto-js は非対応。部分互換、上限40秒。"
        case .ko: return "Apple은 기기에서 번역하며 모델을 다운로드할 수 있습니다. 신뢰하는 Bob 텍스트 플러그인만 가져오세요. 원문과 설정(키 포함)이 허용 호스트로 전송되고 비용이 발생할 수 있습니다. 설정은 키체인에 저장됩니다. 스트리밍, 파일, 음성, OCR, 내장 crypto-js는 지원하지 않습니다. 부분 호환, 최대 40초."
        case .enUS: return "Apple translates on-device and may download language models. Import only trusted Bob text plugins: they can send text and options (including keys) to approved hosts and incur service charges. Options are stored in Keychain. No streaming HTTP, files, speech, OCR or built-in crypto-js. Partial compatibility; 40-second limit."
        }
    }
}
