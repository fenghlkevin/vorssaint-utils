import Foundation

/// Queue-confined JSONL cursor. Unterminated lines (including split UTF-8)
/// remain bytes until the writer appends a newline.
final class CodexIncrementalLog {
    private var identity: String?
    private var modified: Date?
    private(set) var offset: UInt64 = 0
    private var pending = Data()

    func read(_ url: URL) throws -> (reset: Bool, objects: [[String: Any]]) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let date = attributes[.modificationDate] as? Date
        let reset = identity != key || size < offset || (size == offset && modified != date)
        if !reset, size == offset { return (false, []) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if reset {
            identity = key
            offset = size > 512 * 1024 ? size - 512 * 1024 : 0
            pending.removeAll(keepingCapacity: true)
        }
        var discardFirstLine = reset && offset > 0
        try handle.seek(toOffset: offset)
        var objects: [[String: Any]] = []
        // Use the captured size, so a continuously appending writer cannot
        // monopolize this queue. Newly appended bytes belong to the next tick.
        while offset < size {
            let count = Int(min(64 * 1024, size - offset))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
            offset += UInt64(data.count)
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                if discardFirstLine { discardFirstLine = false }
                else if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    objects.append(object)
                }
                pending.removeSubrange(...newline)
            }
        }
        modified = date
        return (reset, objects)
    }
}

enum CodexLogLifecycleState: String {
    case running, completed

    static func event(in object: [String: Any]) -> Self? {
        let type = object["type"] as? String ?? ""
        let payload = object["payload"] as? [String: Any]
        let payloadType = payload?["type"] as? String ?? ""
        if payloadType == "task_started" {
            return .running
        }
        if type == "task_complete" || payloadType == "task_complete"
            || payloadType == "turn_complete" || payloadType == "turn_completed"
            || payloadType == "turn_aborted" {
            return .completed
        }
        // The desktop app renders the final answer before its trailing
        // task_complete event is flushed. Treat that final answer as the
        // end of the current turn so the island changes immediately.
        if type == "event_msg", payloadType == "item_completed",
           let item = payload?["item"] as? [String: Any],
           item["type"] as? String == "AgentMessage",
           item["phase"] as? String == "final_answer" {
            return .completed
        }
        if type == "response_item", payloadType == "message",
           payload?["role"] as? String == "assistant",
           payload?["phase"] as? String == "final_answer" {
            return .completed
        }
        return nil
    }
}
