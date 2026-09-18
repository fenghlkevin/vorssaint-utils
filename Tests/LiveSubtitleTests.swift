import Foundation

@main struct LiveSubtitleTests {
    static func main() {
        assert(LiveSubtitlePolicy.widthPercent(.nan) == 70)
        assert(LiveSubtitlePolicy.widthPercent(120) == 100)
        assert(LiveSubtitlePolicy.windowWidth(screenWidth: 2000, percent: 70) == 1400)
        assert(LiveSubtitlePolicy.windowWidth(screenWidth: 1000, percent: 40) == 600)
        assert(LiveSubtitlePolicy.windowWidth(screenWidth: 500, percent: 70) == 500)
        assert(LiveSubtitlePolicy.acceptAfterClear(start: 0, end: 100, boundary: -1))
        assert(!LiveSubtitlePolicy.acceptAfterClear(start: 0, end: 100, boundary: 100))
        assert(!LiveSubtitlePolicy.acceptAfterClear(start: 0, end: 150, boundary: 100))
        assert(LiveSubtitlePolicy.acceptAfterClear(start: 100, end: 150, boundary: 100))
        assert(LiveSubtitlePolicy.acceptAfterClear(start: 200, end: 250, boundary: 100))
        assert(LiveSubtitlePolicy.visibleCount(3) == 3)
        assert(LiveSubtitlePolicy.visibleCount(0) == 1)
        assert(LiveSubtitlePolicy.visibleCount(99) == 5)
        assert(LiveSubtitlePolicy.fontSize(.nan) == 26)
        assert(LiveSubtitlePolicy.fontSize(100) == 36)
        assert(LiveSubtitlePolicy.opacity(-1) == 0.25)
        assert(LiveSubtitlePolicy.opacity(.infinity) == 0.78)
        assert(LiveSubtitleSegments.split("").isEmpty)
        assert(LiveSubtitleLanguage.japanese.translationCode == "ja")
        assert(LiveSubtitleLanguage.english.translationCode == "en")
        assert(LiveSubtitleLanguage.portugueseBrazil.translationCode == "pt")
        assert(LiveSubtitleLanguage.portuguesePortugal.rawValue == "pt-PT")
        let japanese = "今日はいい天気です。明日も晴れるでしょう！"
        assert(LiveSubtitleSegments.split(japanese, language: .japanese).count == 2)
        assert(LiveSubtitleSegments.split(japanese, language: .japanese).joined() == japanese)
        let longJapanese = String(repeating: "あ", count: 110)
        assert(LiveSubtitleSegments.split(longJapanese, language: .japanese).map(\.count) == [48, 48, 14])
        assert(LiveSubtitleSegments.split("Olá, como você está?", language: .portugueseBrazil).joined(separator: " ") == "Olá, como você está?")
        let text = (1...41).map { "word\($0)" }.joined(separator: " ")
        let chunks = LiveSubtitleSegments.split(text)
        assert(chunks.map { $0.split(separator: " ").count } == [18, 18, 5])
        assert(chunks.joined(separator: " ") == text)
        assert(LiveSubtitlePolicy.mayStart(provider: "system", consent: false))
        for provider in ["codex", "ai:test"] {
            assert(!LiveSubtitlePolicy.mayStart(provider: provider, consent: false))
            assert(LiveSubtitlePolicy.mayStart(provider: provider, consent: true))
            assert(!LiveSubtitlePolicy.shouldTranslate(provider: provider, final: false))
            assert(LiveSubtitlePolicy.shouldTranslate(provider: provider, final: true))
            assert(LiveSubtitlePolicy.queueLimit(provider: provider) == 2)
        }
        assert(LiveSubtitlePolicy.shouldTranslate(provider: "system", final: false))
        assert(LiveSubtitlePolicy.queueLimit(provider: "system") == 8)
        print("LiveSubtitleTests: passed")
    }
}
