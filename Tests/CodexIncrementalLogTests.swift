import Foundation

@main
struct CodexIncrementalLogTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let reader = CodexIncrementalLog()
        func append(_ data: Data) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        try Data("{\"event\":\"start\"}\n".utf8).write(to: file)
        let first = try reader.read(file)
        precondition(first.reset && first.objects.count == 1)
        let originalOffset = reader.offset
        for _ in 0..<100 {
            let unchanged = try reader.read(file)
            precondition(!unchanged.reset && unchanged.objects.isEmpty && reader.offset == originalOffset)
        }
        let text = Data("{\"event\":\"中文完成\"}\n".utf8)
        let split = text.firstIndex(of: 0xe4)! + 1
        try append(text.prefix(split))
        let partial = try reader.read(file)
        precondition(partial.objects.isEmpty)
        try append(text.suffix(from: split))
        let completed = try reader.read(file)
        precondition(completed.objects.count == 1 && completed.objects[0]["event"] as? String == "中文完成")
        try append(Data("not json\n{\"event\":\"approval\"}\n".utf8))
        let valid = try reader.read(file)
        precondition(valid.objects.count == 1)
        // In-place truncation and atomic replacement invalidate the old cursor.
        try Data("{}\n".utf8).write(to: file)
        let truncated = try reader.read(file)
        precondition(truncated.reset)
        try Data("{\"replacement\":true}\n".utf8).write(to: file, options: .atomic)
        let replaced = try reader.read(file)
        precondition(replaced.reset && replaced.objects[0]["replacement"] as? Bool == true)
        // Equal-length in-place rewrites must also invalidate the cursor.
        try Data("{\"replacement\":null}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        let rewritten = try reader.read(file)
        precondition(rewritten.reset && rewritten.objects.count == 1)
        let beforeMissing = reader.offset
        do {
            _ = try reader.read(directory.appendingPathComponent("missing.jsonl"))
            preconditionFailure("missing file should fail")
        } catch { precondition(reader.offset == beforeMissing) }
        // Bootstrapping a large existing log skips its cut first line, but
        // preserves the latest complete lifecycle event at its tail.
        var large = Data(repeating: 120, count: 600 * 1024)
        large.append(Data("\n{\"event\":\"latest\"}\n".utf8))
        try large.write(to: file, options: .atomic)
        let tail = try reader.read(file)
        precondition(tail.reset && tail.objects.count == 1 && tail.objects[0]["event"] as? String == "latest")
        precondition(CodexLogLifecycleState.event(in: ["payload": ["type": "task_started"]]) == .running)
        for name in ["task_complete", "turn_complete", "turn_completed", "turn_aborted"] {
            precondition(CodexLogLifecycleState.event(in: ["payload": ["type": name]]) == .completed)
        }
        precondition(CodexLogLifecycleState.event(in: ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "final_answer"]]) == .completed)
        precondition(CodexLogLifecycleState.event(in: ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "commentary"]]) == nil)
        precondition(CodexLogLifecycleState.event(in: ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "AgentMessage", "phase": "final_answer"]]]) == .completed)
        print("Codex incremental JSONL tests passed (unchanged, append, split UTF-8, malformed line, truncation, replacement, tail bootstrap).")
    }
}
