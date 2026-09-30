import Foundation

struct CodexHookEvent: Codable {
    var event: String
    let sessionID: String
    let project: String
    let title: String
    var detail: String
    var timestamp: Date
    let approvalID: String?
    var approvalExpiresAt: Date? = nil
    var operation: String? = nil
    var cwd: String? = nil
    var terminalApp: String? = nil
    var terminalTTY: String? = nil
    var agentID: String? = nil
}

struct CodexIslandApproval: Equatable, Identifiable {
    let id: String
    let sessionID: String
    let operation: String
    let expiresAt: Date
}

enum CodexHookSupport {
    static let approvalLifetime: TimeInterval = 295
    static func decode(_ data: Data, environment: [String: String], now: Date = Date()) throws -> CodexHookEvent? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["session_id"] as? String, !id.isEmpty,
              let name = object["hook_event_name"] as? String else { return nil }
        let cwd = object["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Codex" : URL(fileURLWithPath: cwd).lastPathComponent
        let input = object["tool_input"] as? [String: Any]
        let tool = object["tool_name"] as? String ?? "工具"
        let operation = (input?["command"] as? String) ?? (input?["description"] as? String)
            ?? (object["tool_input"].flatMap { value in
                (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) }
            }) ?? tool
        let approval = name == "PermissionRequest"
        let event: String
        if name == "Stop", object["status"] as? String == "failed" { event = "Failure" } else { event = name }
        let detail: String
        switch event {
        case "PermissionRequest": detail = (input?["description"] as? String) ?? "请求执行 \(tool)"
        case "Stop": detail = (object["last_assistant_message"] as? String) ?? "任务已完成"
        case "Failure": detail = (object["error"] as? String) ?? "任务执行失败"
        case "Interrupt": detail = "任务已中断"
        case "SessionEnd": detail = "会话已结束"
        case "UserPromptSubmit": detail = "正在分析任务"
        case "PreToolUse", "PostToolUse": detail = "\(event == "PreToolUse" ? "正在执行" : "已执行") \(tool)"
        case "SubagentStart": detail = "子任务已开始"
        case "SubagentStop": detail = "子任务已完成"
        default: detail = "会话已开始"
        }
        return CodexHookEvent(event: event, sessionID: id, project: project,
                              title: String((object["prompt"] as? String ?? "").prefix(160)),
                              detail: String(detail.prefix(2000)), timestamp: now,
                              approvalID: approval ? UUID().uuidString : nil,
                              approvalExpiresAt: approval ? now.addingTimeInterval(approvalLifetime) : nil,
                              operation: approval ? String(operation.prefix(16_000)) + (operation.count > 16_000 ? "\n…内容过长，请返回 Codex 查看完整请求后再决定。" : "") : nil, cwd: cwd,
                              terminalApp: environment["__CFBundleIdentifier"] == "com.openai.codex" ? "Codex" : environment["TERM_PROGRAM"],
                              terminalTTY: object["terminal_tty"] as? String ?? environment["TTY"],
                              agentID: object["agent_id"] as? String)
    }
    static func responseURL(id: String, directory: URL) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return directory.appendingPathComponent(id + ".response")
    }
    static func response(_ decision: String) throws -> Data? {
        guard decision == "allow" || decision == "deny" else { return nil }
        var result = ["behavior": decision]
        if decision == "deny" { result["message"] = "用户在 Vorssaint 中拒绝了此请求。" }
        return try JSONSerialization.data(withJSONObject: ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest", "decision": result
        ]])
    }
}

/// Tracks only explicit question calls and their matching responses, without guessing from prose.
struct CodexQuestionTracker {
    private(set) var callID: String?
    private(set) var prompt: String?
    private var asynchronous = false
    mutating func apply(_ object: [String: Any]) {
        if CodexLogLifecycleState.event(in: object) != nil { callID = nil; prompt = nil }
        if let payload = object["payload"] as? [String: Any], payload["type"] as? String == "user_message" {
            callID = nil; prompt = nil
        }
        guard object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any] else { return }
        let type = payload["type"] as? String
        if type == "function_call_output", !asynchronous, let id = payload["call_id"] as? String, id == callID {
            callID = nil; prompt = nil
        }
        guard type == "function_call", let name = payload["name"] as? String,
              name == "request_user_input" || name == "functions.request_user_input" || name == "request_user_input_async" || name == "functions.request_user_input_async",
              let id = payload["call_id"] as? String else { return }
        callID = id
        asynchronous = name.hasSuffix("_async")
        prompt = "Codex 正在等待你的回答"
        if let arguments = payload["arguments"] as? String,
           let data = arguments.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let questions = values["questions"] as? [[String: Any]] {
            let texts = questions.compactMap { ($0["question"] as? String) ?? ($0["title"] as? String) }
            if !texts.isEmpty { prompt = String(texts.joined(separator: "\n").prefix(1000)) }
        }
    }
}

/// Read-only diagnostics: configuration presence is not evidence that Codex will run it.
enum CodexHookHealth: Equatable {
    case checking, ready, needsTrust, missing, unavailable, cliMissing

    var message: String {
        switch self {
        case .checking: return "正在检查 Codex 审批接入"
        case .ready: return "审批 Hook 已受信任；等待实际事件"
        case .needsTrust: return "审批未接通：请在 Codex /hooks 中信任 Vorssaint"
        case .missing: return "审批 Hook 未启用，请重新启用 AI Hook"
        case .unavailable: return "审批状态检查失败，请稍后重试（不代表未信任）"
        case .cliMissing: return "未找到 Codex 内置命令行，请检查 Codex 安装"
        }
    }

    static func parse(_ data: Data) -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["data"] as? [[String: Any]], !entries.isEmpty else { return .unavailable }
        let hooks = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter {
            $0["eventName"] as? String == "permissionRequest"
                && ($0["command"] as? String)?.contains("--vorssaint-codex-hook") == true
        }
        guard !hooks.isEmpty else { return .missing }
        if hooks.contains(where: { $0["enabled"] as? Bool != true }) { return .missing }
        return hooks.allSatisfy { ["trusted", "managed"].contains($0["trustStatus"] as? String ?? "") } ? .ready : .needsTrust
    }

    static func executable(in applications: [String], isExecutable: (String) -> Bool) -> String? {
        let locations = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                         "Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"]
        return applications.flatMap { app in locations.map { app + "/" + $0 } }.first(where: isExecutable)
    }

    static func inspect() -> Self {
        let candidates = ["/Applications/ChatGPT.app", "/Applications/Codex.app",
                          FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/ChatGPT.app",
                          FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/Codex.app"]
        guard let binary = executable(in: candidates, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }) else { return .cliMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable }
        // This server is used only to inspect configuration, never to own a task or approve it.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        let messages: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "vorssaint-hook-check", "version": "1"], "capabilities": ["experimentalApi": true]]],
            ["method": "initialized"],
            ["id": 2, "method": "hooks/list", "params": ["cwds": [FileManager.default.homeDirectoryForCurrentUser.path]]]
        ]
        do {
            for message in messages {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(10)
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            var buffer = Data()
            while true {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["id"] as? Int == 2 {
                        return parse(line)
                    }
                }
                if buffer.count > 2_000_000 { return .unavailable }
            }
        } catch { return .unavailable }
        return .unavailable
    }
}

/// Kept outside hooks.json so changing presentation does not invalidate hook trust.
enum CodexApprovalDestination: String, CaseIterable {
    case island, codex
    var title: String { self == .island ? "灵动岛" : "Codex 原生" }
}
