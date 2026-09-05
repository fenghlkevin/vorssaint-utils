import Foundation

struct IslandMemo: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var createdAt: Date
    var completed: Bool
    var pinned: Bool
}

final class IslandMemoService: ObservableObject {
    static let shared = IslandMemoService()

    @Published private(set) var memos: [IslandMemo] = []
    private let defaultsKey = "dynamicIsland.memos"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([IslandMemo].self, from: data) {
            memos = saved
        }
    }

    var orderedMemos: [IslandMemo] {
        memos.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.completed != $1.completed { return !$0.completed }
            return $0.createdAt > $1.createdAt
        }
    }

    var completedCount: Int { memos.filter(\.completed).count }

    @discardableResult
    func add(_ value: String, now: Date = Date()) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        memos.append(IslandMemo(id: UUID(), text: text, createdAt: now,
                                completed: false, pinned: false))
        persist()
        return true
    }

    func toggleCompleted(_ id: UUID) { update(id) { $0.completed.toggle() } }
    func togglePinned(_ id: UUID) { update(id) { $0.pinned.toggle() } }
    func delete(_ id: UUID) { memos.removeAll { $0.id == id }; persist() }
    func clearCompleted() { memos.removeAll { $0.completed }; persist() }
    func deleteAll() { memos.removeAll(); persist() }

    private func update(_ id: UUID, mutation: (inout IslandMemo) -> Void) {
        guard let index = memos.firstIndex(where: { $0.id == id }) else { return }
        mutation(&memos[index])
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(memos) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
