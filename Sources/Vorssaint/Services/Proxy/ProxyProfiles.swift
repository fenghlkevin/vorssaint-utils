// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

struct ProxyDraft: Codable, Equatable {
    var yaml: String
    var overrides: String = ""
    func effective() throws -> Data {
        let base = try ProxyConfigCompiler.document(Data(yaml.utf8))
        guard !overrides.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Data(yaml.utf8) }
        let patch = try ProxyConfigCompiler.document(Data(overrides.utf8))
        let managed: Set<String> = ["tun", "secret", "external-controller", "external-controller-tls", "external-controller-unix", "external-ui", "listeners"]
        guard managed.isDisjoint(with: patch.keys) else { throw ProxyFailure.message("覆写不能修改 TUN、Controller、密钥、外部界面或监听器；请在网络设置中管理。") }
        func merge(_ original: [String: Any], _ patch: [String: Any]) -> [String: Any] {
            var result = original
            for (key, value) in patch {
                if let nested = value as? [String: Any], let old = result[key] as? [String: Any] { result[key] = merge(old, nested) }
                else { result[key] = value }
            }
            return result
        }
        return try JSONSerialization.data(withJSONObject: merge(base, patch), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
struct ProxyRevision: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var createdAt = Date()
    var note: String
    var draft: ProxyDraft
}
struct ProxyRevisionIndex: Codable {
    var current: UUID?
    var lastGood: UUID?
    var revisions: [ProxyRevision] = []
}
extension ProxyProfileStore {
    func revisionIndexURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("revisions.json") }
    func revisions(_ id: UUID) throws -> ProxyRevisionIndex {
        guard FileManager.default.fileExists(atPath: revisionIndexURL(id).path) else { return .init() }
        return try JSONDecoder().decode(ProxyRevisionIndex.self, from: Data(contentsOf: revisionIndexURL(id)))
    }
    func committed(_ id: UUID) throws -> ProxyDraft {
        let index = try revisions(id)
        if let revision = index.revisions.first(where: { $0.id == index.current }) { return revision.draft }
        return ProxyDraft(yaml: try String(contentsOf: original(id), encoding: .utf8))
    }
    func draft(_ id: UUID) throws -> ProxyDraft {
        let file = directory(id).appendingPathComponent("draft.json")
        if FileManager.default.fileExists(atPath: file.path) { return try JSONDecoder().decode(ProxyDraft.self, from: Data(contentsOf: file)) }
        return try committed(id)
    }
    func saveDraft(_ draft: ProxyDraft, for id: UUID) throws {
        guard draft.yaml.utf8.count <= 2 * 1024 * 1024, draft.overrides.utf8.count <= 2 * 1024 * 1024 else { throw ProxyFailure.message("草稿和覆写分别不能超过 2 MiB。") }
        try ProxyFiles.write(JSONEncoder().encode(draft), to: directory(id).appendingPathComponent("draft.json"))
    }
    /// One atomic manifest update commits the source, override and history together.
    func commit(_ revision: ProxyRevision, for id: UUID, healthy: Bool) throws {
        var index = try revisions(id)
        if index.revisions.isEmpty { index.revisions.append(.init(note: "导入原件", draft: try committed(id))) }
        index.revisions.append(revision); index.current = revision.id
        if healthy { index.lastGood = revision.id }
        while index.revisions.count > 30 {
            guard let remove = index.revisions.firstIndex(where: { $0.id != index.current && $0.id != index.lastGood }) else { break }
            index.revisions.remove(at: remove)
        }
        try ProxyFiles.write(JSONEncoder().encode(index), to: revisionIndexURL(id))
    }
    func markHealthy(_ id: UUID) throws {
        var index = try revisions(id)
        if index.current == nil {
            let baseline = ProxyRevision(note: "首次验证通过", draft: try committed(id))
            index.revisions.append(baseline); index.current = baseline.id
        }
        index.lastGood = index.current
        try ProxyFiles.write(JSONEncoder().encode(index), to: revisionIndexURL(id))
    }
    func rename(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw ProxyFailure.message("配置名需为 1–200 个字符。") }
        var index = try profiles()
        guard let position = index.firstIndex(where: { $0.id == id }) else { throw ProxyFailure.message("配置不存在。") }
        index[position].name = name
        try ProxyFiles.write(JSONEncoder().encode(index), to: indexURL)
    }
    func remove(_ id: UUID) throws {
        let index = try profiles().filter { $0.id != id }
        try ProxyFiles.write(JSONEncoder().encode(index), to: indexURL)
        try FileManager.default.removeItem(at: directory(id))
    }
    func duplicate(_ id: UUID) throws -> ProxyProfile {
        let index = try profiles()
        let source = try committed(id)
        let copied = try importProfile(data: Data(source.yaml.utf8), name: (index.first { $0.id == id }?.name ?? "配置") + " 副本")
        try commit(.init(note: "复制配置", draft: source), for: copied.id, healthy: false)
        return copied
    }
}

enum ProxyDiff {
    /// Bounded display diff: common prefix/suffix, then the changed block. Never logged.
    static func text(before: String, after: String) -> String {
        let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        if prefix == a.count && prefix == b.count { return "无变化" }
        let removed = a[prefix..<(a.count - suffix)].prefix(250).map { "− " + $0 }
        let added = b[prefix..<(b.count - suffix)].prefix(250).map { "+ " + $0 }
        return (["从第 \(prefix + 1) 行开始；每侧最多展示 250 行"] + removed + added).joined(separator: "\n")
    }
}

struct ProxyApplyJournal: Codable {
    let previousSelection: UUID?
    let target: UUID
    let previousIndex: ProxyRevisionIndex
    let previousRuntime: String?
}
extension ProxyProfileStore {
    private var applyJournalURL: URL { root.appendingPathComponent("pending-apply.json") }
    func beginApply(previous: UUID?, target: UUID) throws {
        let journal = ProxyApplyJournal(previousSelection: previous, target: target, previousIndex: try revisions(target), previousRuntime: try? String(contentsOf: directory(target).appendingPathComponent("runtime-location.txt"), encoding: .utf8))
        try ProxyFiles.write(JSONEncoder().encode(journal), to: applyJournalURL)
    }
    func finishApply() throws {
        if FileManager.default.fileExists(atPath: applyJournalURL.path) { try FileManager.default.removeItem(at: applyJournalURL) }
    }
    func recoverApply() throws {
        guard FileManager.default.fileExists(atPath: applyJournalURL.path) else { return }
        let journal = try JSONDecoder().decode(ProxyApplyJournal.self, from: Data(contentsOf: applyJournalURL))
        try ProxyFiles.write(JSONEncoder().encode(journal.previousIndex), to: revisionIndexURL(journal.target))
        let selected = root.appendingPathComponent("selected-profile.json")
        if let previous = journal.previousSelection { try ProxyFiles.write(JSONEncoder().encode(previous), to: selected) }
        else if FileManager.default.fileExists(atPath: selected.path) { try FileManager.default.removeItem(at: selected) }
        let runtime = directory(journal.target).appendingPathComponent("runtime-location.txt")
        if let previous = journal.previousRuntime { try ProxyFiles.write(Data(previous.utf8), to: runtime) }
        else if FileManager.default.fileExists(atPath: runtime.path) { try FileManager.default.removeItem(at: runtime) }
        try finishApply()
    }
}

extension ProxyProfileStore {
    func savedRuntime(_ id: UUID) throws -> URL {
        let file = directory(id).appendingPathComponent("runtime-location.txt")
        guard FileManager.default.fileExists(atPath: file.path) else { return runtime(id) }
        let name = try String(contentsOf: file, encoding: .utf8)
        guard name.hasPrefix("candidate-"), UUID(uuidString: String(name.dropFirst(10))) != nil else { throw ProxyFailure.message("运行缓存路径记录无效。") }
        return runtime(id).appendingPathComponent(name)
    }
    func saveRuntime(_ work: URL, for id: UUID) throws {
        guard work.deletingLastPathComponent().standardizedFileURL == runtime(id).standardizedFileURL,
              work.lastPathComponent.hasPrefix("candidate-"), UUID(uuidString: String(work.lastPathComponent.dropFirst(10))) != nil else { throw ProxyFailure.message("候选缓存路径无效。") }
        try ProxyFiles.write(Data(work.lastPathComponent.utf8), to: directory(id).appendingPathComponent("runtime-location.txt"))
    }
    func pruneRuntime(_ id: UUID, keeping: URL) throws {
        let candidates = try FileManager.default.contentsOfDirectory(at: runtime(id), includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]).filter { $0.lastPathComponent.hasPrefix("candidate-") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let sorted = candidates.sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for file in sorted.dropFirst(3) where file.standardizedFileURL != keeping.standardizedFileURL { try FileManager.default.removeItem(at: file) }
    }
}
