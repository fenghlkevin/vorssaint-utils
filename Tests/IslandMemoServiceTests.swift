import Foundation

@main struct IslandMemoServiceTests {
    static func main() throws {
        let name = "island-memo-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID()
        let legacy = """
        [{"id":"\(id.uuidString)","text":"旧备忘\\n第二行","createdAt":0,"completed":true,"pinned":true}]
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: "dynamicIsland.memos")
        let service = IslandMemoService(defaults: defaults)
        precondition(service.memos.count == 1 && service.memos[0].text == "旧备忘\n第二行")
        precondition(service.memos[0].completed && service.memos[0].pinned)
        var memo = service.memos[0]
        memo.title = "新标题"; memo.text = "修改正文"; memo.colorIndex = 3
        service.save(memo)
        let reloaded = IslandMemoService(defaults: defaults)
        precondition(reloaded.memos[0].title == "新标题" && reloaded.memos[0].colorIndex == 3)
        precondition(reloaded.memos[0].completed && reloaded.memos[0].pinned)
        service.delete(id)
        precondition(service.memos.isEmpty)
        service.undoDelete()
        precondition(service.memos.count == 1 && service.memos[0].text == "修改正文")
        memo.title = ""; memo.text = ""
        service.save(memo)
        precondition(service.memos[0].text.isEmpty, "Existing note edits can clear content")
        service.save(IslandMemo(id: UUID(), text: "", createdAt: Date(), completed: false, pinned: false))
        precondition(service.memos.count == 1, "Empty drafts must not create notes")
        service.deleteAll(); service.undoDelete(); service.undoDelete()
        precondition(service.memos.count == 1)
        print("PASS: legacy migration, editing, color persistence, empty drafts and undo deletion")
    }
}
