import Foundation

@main struct PreviewSegmentsTests {
    static func main() {
        assert(PreviewSegments.split("").isEmpty)
        assert(PreviewSegments.split("hello world") == ["hello world"])
        let long = (1...41).map { "word\($0)" }.joined(separator: " ")
        let chunks = PreviewSegments.split(long)
        assert(chunks.map { $0.split(separator: " ").count } == [18, 18, 5])
        assert(chunks.joined(separator: " ") == long)
        let sentence = "This is a complete sentence. Here is another complete sentence."
        assert(PreviewSegments.split(sentence).count == 2)
        assert(PreviewSegments.split("one\n two\tthree") == ["one two three"])
        assert(PreviewSegments.split(long + " extra").first == chunks.first)
        print("PreviewSegments: 6 tests passed")
    }
}
