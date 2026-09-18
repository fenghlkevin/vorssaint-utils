import Foundation

enum PreviewSegments {
    // Bounded English chunks. Whole words only; fixed word boundaries limit preview churn.
    static func split(_ text: String) -> [String] {
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
