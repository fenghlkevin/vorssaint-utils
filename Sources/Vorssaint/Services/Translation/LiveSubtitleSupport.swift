import Foundation

enum LiveSubtitleLanguage: String, CaseIterable {
    case english = "en-US", japanese = "ja-JP", portugueseBrazil = "pt-BR", portuguesePortugal = "pt-PT"
    var title: String {
        switch self {
        case .english: return "英语"
        case .japanese: return "日语"
        case .portugueseBrazil: return "葡萄牙语（巴西）"
        case .portuguesePortugal: return "葡萄牙语（葡萄牙）"
        }
    }
    var translationCode: String {
        switch self {
        case .english: return "en"
        case .japanese: return "ja"
        case .portugueseBrazil, .portuguesePortugal: return "pt"
        }
    }
}

enum LiveSubtitleSegments {
    // Bounded English chunks. Whole words only; fixed word boundaries limit preview churn.
    static func split(_ text: String, language: LiveSubtitleLanguage = .english) -> [String] {
        if language == .japanese {
            var result: [String] = []
            var chunk = ""
            for character in text {
                chunk.append(character)
                if chunk.count >= 48 || "。！？!?\n".contains(character) {
                    if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(chunk) }
                    chunk = ""
                }
            }
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(chunk) }
            return result
        }
        var result: [String] = []
        var words: [String] = []
        for word in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            words.append(word)
            if words.count >= 18 || (words.count >= 5 && word.last.map { ".!?;:".contains($0) } == true) {
                result.append(words.joined(separator: " ")); words = []
            }
        }
        if !words.isEmpty { result.append(words.joined(separator: " ")) }
        return result
    }
}


enum LiveSubtitlePolicy {
    static func widthPercent(_ value: Double) -> Double { value.isFinite ? min(100, max(40, value)) : 70 }
    static func windowWidth(screenWidth: Double, percent: Double) -> Double {
        min(screenWidth, max(600, screenWidth * widthPercent(percent) / 100))
    }
    static func acceptAfterClear(start: Int64, end: Int64, boundary: Int64) -> Bool {
        boundary < 0 || (start >= boundary && end > boundary)
    }
    static func visibleCount(_ value: Int) -> Int { min(5, max(1, value)) }
    static func fontSize(_ value: Double) -> Double { value.isFinite ? min(36, max(18, value)) : 26 }
    static func opacity(_ value: Double) -> Double { value.isFinite ? min(0.95, max(0.25, value)) : 0.78 }
    static func mayStart(provider: String, consent: Bool) -> Bool { provider == "system" || consent }
    static func shouldTranslate(provider: String, final: Bool) -> Bool { provider == "system" || final }
    static func queueLimit(provider: String) -> Int { provider == "system" ? 8 : 2 }
}
