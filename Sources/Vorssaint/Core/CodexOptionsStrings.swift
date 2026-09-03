// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

extension TranslationStrings {
    var codexOptions: (model: String, speed: String, effort: String, automatic: String, standard: String, fast: String, refresh: String, notice: String) {
        switch language {
        case .zhHans: return ("模型", "速度", "推理强度", "CLI 默认", "标准（默认）", "快速（更多额度）", "刷新模型", "模型目录来自本机 CLI，实际可用性取决于账户。先选择模型，再选择其支持的速度和强度；切换模型会重置这两项。快速模式可能消耗更多额度，较高强度通常更慢。设置自动保存。")
        case .zhTW, .zhHK: return ("模型", "速度", "推理強度", "CLI 預設", "標準（預設）", "快速（更多額度）", "重新整理模型", "模型目錄來自本機 CLI，實際可用性取決於帳戶。先選模型，再選其支援的速度與強度；切換模型會重設這兩項。快速模式可能消耗更多額度，較高強度通常更慢。設定自動儲存。")
        case .enUS: return ("Model", "Speed", "Reasoning effort", "CLI default", "Standard (default)", "Fast (higher usage)", "Refresh models", "Models come from the local CLI; availability depends on your account. Choose a model to see supported speeds and efforts. Changing model resets both. Fast may use more quota; higher effort usually takes longer. Settings save automatically.")
        case .ptBR: return ("Modelo", "Velocidade", "Esforço de raciocínio", "Padrão do CLI", "Padrão", "Rápido (maior uso)", "Atualizar modelos", "Catálogo do CLI local; disponibilidade depende da conta. Escolha um modelo para ver opções compatíveis. Trocar modelo redefine ambas. Rápido pode usar mais cota; maior esforço costuma demorar mais. Salvo automaticamente.")
        case .tr: return ("Model", "Hız", "Akıl yürütme düzeyi", "CLI varsayılanı", "Standart", "Hızlı (daha fazla kullanım)", "Modelleri yenile", "Liste yerel CLI’den gelir; erişim hesaba bağlıdır. Desteklenen hız ve düzey için model seçin. Model değişikliği ikisini sıfırlar. Hızlı mod daha fazla kota, yüksek düzey daha fazla süre kullanabilir. Otomatik kaydedilir.")
        case .ru: return ("Модель", "Скорость", "Глубина рассуждений", "По умолчанию CLI", "Стандартная", "Быстро (больше квоты)", "Обновить модели", "Каталог из локального CLI; доступ зависит от аккаунта. Выберите модель для доступных скоростей и глубины. Смена модели сбрасывает оба параметра. Быстрый режим может расходовать больше квоты, глубокий — больше времени. Автосохранение.")
        case .es: return ("Modelo", "Velocidad", "Esfuerzo de razonamiento", "Predeterminado del CLI", "Estándar", "Rápido (mayor uso)", "Actualizar modelos", "Catálogo del CLI local; disponibilidad según cuenta. Elige un modelo para ver opciones compatibles. Cambiar modelo restablece ambas. Rápido puede consumir más cuota y mayor esfuerzo tarda más. Guardado automático.")
        case .de: return ("Modell", "Geschwindigkeit", "Denkaufwand", "CLI-Standard", "Standard", "Schnell (höherer Verbrauch)", "Modelle aktualisieren", "Katalog aus lokaler CLI; Verfügbarkeit kontobedingt. Modell für unterstützte Optionen wählen. Modellwechsel setzt beide zurück. Schnell kann mehr Kontingent, höherer Denkaufwand mehr Zeit benötigen. Automatisches Speichern.")
        case .fr: return ("Modèle", "Vitesse", "Effort de raisonnement", "Défaut CLI", "Standard", "Rapide (usage accru)", "Actualiser les modèles", "Catalogue du CLI local ; accès selon le compte. Choisissez un modèle pour les options compatibles. Changer de modèle réinitialise les deux. Rapide peut consommer plus de quota, un effort élevé prend plus de temps. Enregistrement automatique.")
        case .it: return ("Modello", "Velocità", "Sforzo di ragionamento", "Predefinito CLI", "Standard", "Rapido (uso maggiore)", "Aggiorna modelli", "Catalogo dal CLI locale; disponibilità in base all’account. Scegli un modello per le opzioni supportate. Cambiare modello reimposta entrambe. Rapido può consumare più quota, maggiore sforzo richiede più tempo. Salvataggio automatico.")
        case .ja: return ("モデル", "速度", "推論の強度", "CLI 既定値", "標準（既定）", "高速（使用量増加）", "モデルを更新", "ローカル CLI の一覧です。利用可否はアカウントによります。モデルを選ぶと対応する速度と強度を選択できます。モデル変更で両方リセットします。高速は利用枠を多く消費し、高い強度は時間がかかる場合があります。自動保存します。")
        case .ko: return ("모델", "속도", "추론 강도", "CLI 기본값", "표준 (기본)", "빠름 (사용량 증가)", "모델 새로고침", "로컬 CLI 목록이며 사용 가능 여부는 계정에 따라 다릅니다. 모델을 선택하면 지원 속도와 강도를 고를 수 있습니다. 모델 변경 시 둘 다 초기화됩니다. 빠른 모드는 한도를 더 쓰고 높은 강도는 시간이 더 걸릴 수 있습니다. 자동 저장됩니다.")
        }
    }
    func codexEffort(_ value: String) -> String {
        let keys = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        let values: [String]
        switch language {
        case .zhHans: values = ["无", "最低", "低", "中", "高", "很高", "最大", "极致"]
        case .zhTW, .zhHK: values = ["無", "最低", "低", "中", "高", "很高", "最大", "極致"]
        case .enUS: values = ["None", "Minimal", "Low", "Medium", "High", "Extra high", "Maximum", "Ultra"]
        case .ptBR: values = ["Nenhum", "Mínimo", "Baixo", "Médio", "Alto", "Muito alto", "Máximo", "Ultra"]
        case .tr: values = ["Yok", "En az", "Düşük", "Orta", "Yüksek", "Çok yüksek", "En yüksek", "Ultra"]
        case .ru: values = ["Нет", "Минимальная", "Низкая", "Средняя", "Высокая", "Очень высокая", "Максимальная", "Ультра"]
        case .es: values = ["Ninguno", "Mínimo", "Bajo", "Medio", "Alto", "Muy alto", "Máximo", "Ultra"]
        case .de: values = ["Keiner", "Minimal", "Niedrig", "Mittel", "Hoch", "Sehr hoch", "Maximal", "Ultra"]
        case .fr: values = ["Aucun", "Minimal", "Faible", "Moyen", "Élevé", "Très élevé", "Maximum", "Ultra"]
        case .it: values = ["Nessuno", "Minimo", "Basso", "Medio", "Alto", "Molto alto", "Massimo", "Ultra"]
        case .ja: values = ["なし", "最小", "低", "中", "高", "非常に高い", "最大", "ウルトラ"]
        case .ko: values = ["없음", "최소", "낮음", "중간", "높음", "매우 높음", "최대", "울트라"]
        }
        return keys.firstIndex(of: value).map { values[$0] + " · " + value } ?? value
    }
}
