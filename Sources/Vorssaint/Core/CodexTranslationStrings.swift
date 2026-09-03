// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

extension TranslationStrings {
    var codexNotice: String {
        switch language {
        case .zhHans: return "使用已安装并登录的 Codex CLI；无需填写 Key。路径留空自动检测，模型留空使用 CLI 默认模型。设置自动保存。原文会发送到 Codex 云端并消耗账户额度，并非离线免费翻译。请先在终端运行 codex login。独立临时会话，禁用命令、浏览器及插件，120 秒超时。"
        case .zhTW, .zhHK: return "使用已安裝並登入的 Codex CLI；無需填寫 Key。路徑留空自動偵測，模型留空使用 CLI 預設模型。設定自動儲存。原文會傳送到 Codex 雲端並消耗帳戶額度，並非離線免費翻譯。請先在終端執行 codex login。獨立臨時工作階段，停用命令、瀏覽器及外掛，120 秒逾時。"
        case .enUS: return "Uses an installed, signed-in Codex CLI; no Key required. Blank path: auto-detect; blank model: CLI default. Settings save automatically. Text is sent to the Codex cloud and uses account quota, not free offline translation. Run codex login in Terminal first. Temporary session; commands, browser and plugins disabled; 120-second timeout."
        case .ptBR: return "Usa o Codex CLI instalado e conectado, sem chave. Caminho vazio: detectar; modelo vazio: padrão do CLI. Salva automaticamente. Envia texto à nuvem e consome a cota da conta; não é tradução gratuita offline. Execute codex login no Terminal. Sessão temporária; comandos, navegador e plugins desativados; limite de 120 s."
        case .tr: return "Kurulu ve oturum açılmış Codex CLI kullanılır; anahtar gerekmez. Boş yol: otomatik; boş model: CLI varsayılanı. Otomatik kaydedilir. Metin buluta gönderilir ve hesap kotasını kullanır; ücretsiz çevrimdışı çeviri değildir. Terminal’de codex login çalıştırın. Geçici oturum; komut, tarayıcı ve eklentiler kapalı; süre 120 sn."
        case .ru: return "Используется установленный Codex CLI с выполненным входом, без ключа. Пустой путь: авто; пустая модель: стандарт CLI. Автосохранение. Текст отправляется в облако и расходует квоту, это не бесплатный офлайн-перевод. Выполните codex login в Терминале. Временный сеанс; команды, браузер и плагины отключены; тайм-аут 120 с."
        case .es: return "Usa Codex CLI instalado con sesión iniciada, sin clave. Ruta vacía: detectar; modelo vacío: predeterminado. Guardado automático. Envía texto a la nube y consume cuota; no es traducción gratuita sin conexión. Ejecuta codex login en Terminal. Sesión temporal; comandos, navegador y plugins desactivados; límite de 120 s."
        case .de: return "Nutzt die installierte, angemeldete Codex CLI ohne Schlüssel. Pfad leer: automatisch; Modell leer: CLI-Standard. Automatisches Speichern. Text geht in die Cloud und nutzt Kontokontingent; nicht kostenlos offline. Zuerst codex login im Terminal. Temporäre Sitzung; Befehle, Browser und Plugins deaktiviert; Zeitlimit 120 s."
        case .fr: return "Utilise Codex CLI installé et connecté, sans clé. Chemin vide : détection ; modèle vide : défaut CLI. Enregistrement automatique. Envoie le texte au cloud et consomme le quota, pas de traduction gratuite hors ligne. Lancez codex login dans Terminal. Session temporaire ; commandes, navigateur et plugins désactivés ; délai 120 s."
        case .it: return "Usa Codex CLI installato con accesso effettuato, senza chiave. Percorso vuoto: automatico; modello vuoto: predefinito CLI. Salvataggio automatico. Invia testo al cloud e consuma la quota, non è traduzione gratuita offline. Esegui codex login nel Terminale. Sessione temporanea; comandi, browser e plugin disabilitati; limite 120 s."
        case .ja: return "インストール・ログイン済みの Codex CLI を使います。キー不要。パス空欄は自動検出、モデル空欄は CLI 既定値。自動保存します。原文はクラウドに送信され利用枠を消費するため、無料のオフライン翻訳ではありません。先にターミナルで codex login を実行してください。一時セッションでコマンド・ブラウザ・プラグインを無効化し、120 秒でタイムアウトします。"
        case .ko: return "설치 및 로그인된 Codex CLI를 사용하며 키가 필요 없습니다. 빈 경로는 자동 감지, 빈 모델은 CLI 기본값입니다. 자동 저장됩니다. 원문을 클라우드로 보내 계정 한도를 사용하며 무료 오프라인 번역이 아닙니다. 먼저 터미널에서 codex login을 실행하세요. 임시 세션, 명령·브라우저·플러그인 비활성화, 제한 시간 120초."
        }
    }
    var codexFailure: String {
        switch language {
        case .zhHans: return "Codex 翻译失败：请检查 CLI 路径、版本、登录状态、网络及模型／账户额度。"
        case .zhTW, .zhHK: return "Codex 翻譯失敗：請檢查 CLI 路徑、版本、登入狀態、網絡及模型／帳戶額度。"
        case .enUS: return "Codex translation failed. Check CLI path/version, login, network, model and quota."
        case .ptBR: return "Falha no Codex. Verifique caminho/versão do CLI, login, rede, modelo e cota."
        case .tr: return "Codex çevirisi başarısız. CLI yolu/sürümü, oturum, ağ, model ve kotayı kontrol edin."
        case .ru: return "Ошибка перевода Codex. Проверьте путь/версию CLI, вход, сеть, модель и квоту."
        case .es: return "Error de Codex. Revisa ruta/versión del CLI, sesión, red, modelo y cuota."
        case .de: return "Codex-Übersetzung fehlgeschlagen. CLI-Pfad/Version, Anmeldung, Netzwerk, Modell und Kontingent prüfen."
        case .fr: return "Échec de Codex. Vérifiez chemin/version CLI, connexion, réseau, modèle et quota."
        case .it: return "Traduzione Codex non riuscita. Controlla percorso/versione CLI, accesso, rete, modello e quota."
        case .ja: return "Codex 翻訳に失敗しました。CLI パス・バージョン、ログイン、ネットワーク、モデル・利用枠を確認してください。"
        case .ko: return "Codex 번역 실패. CLI 경로·버전, 로그인, 네트워크, 모델·한도를 확인하세요."
        }
    }
}
