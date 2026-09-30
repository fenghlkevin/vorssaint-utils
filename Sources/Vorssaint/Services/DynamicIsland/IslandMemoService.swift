import Foundation
import Combine

struct IslandMemo: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var createdAt: Date
    var completed: Bool
    var pinned: Bool
    // Optional fields preserve decoding of existing text-only memos.
    var title: String? = nil
    var colorIndex: Int? = nil
    var modifiedAt: Date? = nil

    var displayTitle: String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (text.split(separator: "\n").first.map(String.init) ?? "未命名备忘") : title
    }
    var modificationDate: Date { modifiedAt ?? createdAt }
}

final class IslandMemoService: ObservableObject {
    static let shared = IslandMemoService()

    @Published private(set) var memos: [IslandMemo] = []
    @Published private(set) var deletedMemos: [IslandMemo] = []
    private let defaults: UserDefaults
    private let defaultsKey = "dynamicIsland.memos"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([IslandMemo].self, from: data) {
            memos = saved
        }
    }

    var orderedMemos: [IslandMemo] {
        memos.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.completed != $1.completed { return !$0.completed }
            return $0.modificationDate > $1.modificationDate
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
    func save(_ memo: IslandMemo, now: Date = Date()) {
        guard memos.contains(where: { $0.id == memo.id }) || !(memo.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !memo.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var updated = memo
        updated.colorIndex = min(max(memo.colorIndex ?? 0, 0), 5)
        if let index = memos.firstIndex(where: { $0.id == memo.id }) {
            // Preserve list-level state while an editor is open.
            updated.pinned = memos[index].pinned
            updated.completed = memos[index].completed
            updated.modifiedAt = memos[index].modifiedAt
            guard updated != memos[index] else { return }
            updated.modifiedAt = now
            memos[index] = updated
        } else {
            updated.modifiedAt = now
            memos.append(updated)
        }
        persist()
    }

    func delete(_ id: UUID) { remove { $0.id == id } }
    func clearCompleted() { remove { $0.completed } }
    func deleteAll() { remove { _ in true } }
    private func remove(where predicate: (IslandMemo) -> Bool) {
        deletedMemos = memos.filter(predicate)
        memos.removeAll(where: predicate)
        persist()
    }
    func undoDelete() {
        memos.append(contentsOf: deletedMemos.filter { deleted in !memos.contains { $0.id == deleted.id } })
        deletedMemos = []
        persist()
    }

    private func update(_ id: UUID, mutation: (inout IslandMemo) -> Void) {
        guard let index = memos.firstIndex(where: { $0.id == id }) else { return }
        mutation(&memos[index])
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(memos) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
