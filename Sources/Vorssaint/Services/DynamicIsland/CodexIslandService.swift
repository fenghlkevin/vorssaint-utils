import AppKit
import CoreText
import Foundation

struct CodexIslandSession: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case running, waiting, completed, failed }
    let id: String
    var project: String
    var title: String
    var detail: String
    var status: Status
    var startedAt: Date
    var updatedAt: Date
}

private struct CodexHookEvent: Codable {
    let event: String
    let sessionID: String
    let project: String
    let title: String
    let detail: String
    let timestamp: Date
}

/// Receives small, local-only state envelopes written by the Codex hook
/// subprocess. Full prompts, tool inputs and transcripts are never persisted.
final class CodexIslandService: ObservableObject {
    static let shared = CodexIslandService()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: DefaultsKey.dynamicIslandCodexEnabled)
            syncHookInstallation()
        }
    }
    @Published private(set) var sessions: [CodexIslandSession] = []
    @Published private(set) var hookInstalled = false
    @Published private(set) var lastError: String?
    @Published var soundEnabled: Bool { didSet { UserDefaults.standard.set(soundEnabled, forKey: "dynamicIsland.codexSoundEnabled") } }
    @Published var soundVolume: Double { didSet { UserDefaults.standard.set(soundVolume, forKey: "dynamicIsland.codexSoundVolume") } }
    @Published var expandOnCompletion: Bool { didSet { UserDefaults.standard.set(expandOnCompletion, forKey: "dynamicIsland.codexExpandOnCompletion") } }
    @Published var muteWhileLocked: Bool { didSet { UserDefaults.standard.set(muteWhileLocked, forKey: "dynamicIsland.codexMuteWhileLocked") } }
    @Published var showProjectName: Bool { didSet { UserDefaults.standard.set(showProjectName, forKey: "dynamicIsland.codexShowProject") } }
    @Published var showActivityDetail: Bool { didSet { UserDefaults.standard.set(showActivityDetail, forKey: "dynamicIsland.codexShowActivity") } }
    @Published var displayMode: String { didSet { UserDefaults.standard.set(displayMode, forKey: "dynamicIsland.codexDisplayMode") } }
    @Published var contentFontSize: Double { didSet { UserDefaults.standard.set(contentFontSize, forKey: "dynamicIsland.codexFontSize") } }
    @Published var panelWidth: Double { didSet { UserDefaults.standard.set(panelWidth, forKey: "dynamicIsland.codexPanelWidth") } }
    @Published var panelHeight: Double { didSet { UserDefaults.standard.set(panelHeight, forKey: "dynamicIsland.codexPanelHeight") } }
    @Published var showSubagents: Bool { didSet { UserDefaults.standard.set(showSubagents, forKey: "dynamicIsland.codexShowSubagents") } }
    @Published var subagentNotification: String { didSet { UserDefaults.standard.set(subagentNotification, forKey: "dynamicIsland.codexSubagentNotification") } }
    @Published var builtInFiltersEnabled: Bool { didSet { UserDefaults.standard.set(builtInFiltersEnabled, forKey: "dynamicIsland.codexBuiltInFilters") } }
    @Published var pathFilters: String { didSet { UserDefaults.standard.set(pathFilters, forKey: "dynamicIsland.codexPathFilters") } }
    @Published var promptFilters: String { didSet { UserDefaults.standard.set(promptFilters, forKey: "dynamicIsland.codexPromptFilters") } }

    private var consumedFiles = Set<String>()
    private var firstRefresh = true
    private var logTitles: [String: String] = [:]

    private init() {
        enabled = UserDefaults.standard.object(forKey: DefaultsKey.dynamicIslandCodexEnabled) as? Bool ?? true
        soundEnabled = UserDefaults.standard.object(forKey: "dynamicIsland.codexSoundEnabled") as? Bool ?? true
        soundVolume = UserDefaults.standard.object(forKey: "dynamicIsland.codexSoundVolume") as? Double ?? 0.3
        expandOnCompletion = UserDefaults.standard.object(forKey: "dynamicIsland.codexExpandOnCompletion") as? Bool ?? true
        muteWhileLocked = UserDefaults.standard.object(forKey: "dynamicIsland.codexMuteWhileLocked") as? Bool ?? true
        showProjectName = UserDefaults.standard.object(forKey: "dynamicIsland.codexShowProject") as? Bool ?? true
        showActivityDetail = UserDefaults.standard.object(forKey: "dynamicIsland.codexShowActivity") as? Bool ?? true
        displayMode = UserDefaults.standard.string(forKey: "dynamicIsland.codexDisplayMode") ?? "detailed"
        contentFontSize = UserDefaults.standard.object(forKey: "dynamicIsland.codexFontSize") as? Double ?? 11
        panelWidth = UserDefaults.standard.object(forKey: "dynamicIsland.codexPanelWidth") as? Double ?? 600
        let storedPanelHeight = UserDefaults.standard.object(forKey: "dynamicIsland.codexPanelHeight") as? Double
        panelHeight = storedPanelHeight == nil || storedPanelHeight! <= 320 ? 560 : storedPanelHeight!
        showSubagents = UserDefaults.standard.object(forKey: "dynamicIsland.codexShowSubagents") as? Bool ?? true
        subagentNotification = UserDefaults.standard.string(forKey: "dynamicIsland.codexSubagentNotification") ?? "main"
        builtInFiltersEnabled = UserDefaults.standard.object(forKey: "dynamicIsland.codexBuiltInFilters") as? Bool ?? true
        pathFilters = UserDefaults.standard.string(forKey: "dynamicIsland.codexPathFilters") ?? ""
        promptFilters = UserDefaults.standard.string(forKey: "dynamicIsland.codexPromptFilters") ?? ""
        if let fontURL = Bundle.main.url(forResource: "DepartureMono-Regular", withExtension: "otf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }

    var activeSession: CodexIslandSession? {
        sessions.sorted { lhs, rhs in
            if lhs.status == .waiting, rhs.status != .waiting { return true }
            if rhs.status == .waiting, lhs.status != .waiting { return false }
            return lhs.updatedAt > rhs.updatedAt
        }.first
    }

    func syncHookInstallation() {
        do {
            if enabled { try CodexHookInstaller.install() }
            else { try CodexHookInstaller.uninstall() }
            hookInstalled = enabled
            lastError = nil
        } catch {
            hookInstalled = false
            lastError = error.localizedDescription
        }
    }

    func refresh() {
        guard enabled else { return }
        let fm = FileManager.default
        let directory = CodexHookBridge.inboxDirectory
        let urls = (try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })) ?? []
        var attention = false
        for url in urls where !consumedFiles.contains(url.lastPathComponent) {
            consumedFiles.insert(url.lastPathComponent)
            guard let data = try? Data(contentsOf: url),
                  let event = try? JSONDecoder.codexIsland.decode(CodexHookEvent.self, from: data) else {
                try? fm.removeItem(at: url)
                continue
            }
            attention = apply(event) || attention
            try? fm.removeItem(at: url)
        }
        refreshSessionLogs()
        sessions.removeAll { Date().timeIntervalSince($0.updatedAt) > 2 * 60 * 60 }
        if attention, !firstRefresh {
            let shouldExpand = sessions.first?.status != .completed || expandOnCompletion
            if shouldExpand {
                let duration: TimeInterval = sessions.first?.status == .completed ? 4 : 5
                DynamicIslandService.shared.activateCodex(duration: duration)
            }
        }
        firstRefresh = false
    }

    /// Codex Desktop can keep a hook list cached for an already-running task.
    /// Its local JSONL session stream is therefore used as a read-only live
    /// fallback; hooks remain authoritative for permission and stop events.
    private func refreshSessionLogs() {
        let calendar = Calendar.current
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        var candidates: [(URL, Date)] = []
        for offset in 0...1 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                           includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      Date().timeIntervalSince(modified) < 2 * 60 * 60 else { continue }
                candidates.append((url, modified))
            }
        }
        for (url, modified) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(8) {
            guard let metadata = sessionMetadata(at: url), metadata.threadSource == "user" else { continue }
            let id = metadata.id
            if let existing = sessions.firstIndex(where: { $0.id == id }),
               sessions[existing].status == .waiting,
               Date().timeIntervalSince(sessions[existing].updatedAt) < 5 * 60 { continue }
            let title = logTitles[url.path] ?? sessionTitle(at: url, fallback: metadata.project)
            guard !isFiltered(cwd: metadata.cwd, prompt: title) else { continue }
            logTitles[url.path] = title
            let status = sessionStatus(at: url, modified: modified)
            let detail = sessionDetail(at: url, status: status)
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                let previousStatus = sessions[index].status
                sessions[index].title = title
                sessions[index].project = metadata.project
                sessions[index].detail = detail
                sessions[index].status = status
                sessions[index].updatedAt = modified
                if !firstRefresh, previousStatus == .running, status == .completed {
                    play(.completed)
                    if expandOnCompletion {
                        DynamicIslandService.shared.activateCodex(duration: 4)
                    }
                }
            } else {
                sessions.append(CodexIslandSession(id: id, project: metadata.project, title: title,
                                                    detail: detail, status: status,
                                                    startedAt: metadata.startedAt, updatedAt: modified))
                if !firstRefresh, Date().timeIntervalSince(modified) < 15 { play(.started) }
            }
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func sessionMetadata(at url: URL) -> (id: String, project: String, cwd: String, threadSource: String, startedAt: Date)? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 256 * 1024),
              let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        try? handle.close()
        let source: String
        if let value = payload["thread_source"] as? String { source = value }
        else { source = "" }
        let id = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? url.lastPathComponent
        let cwd = payload["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Codex" : URL(fileURLWithPath: cwd).lastPathComponent
        let startedAt = ISO8601DateFormatter().date(from: payload["timestamp"] as? String ?? "") ?? Date()
        return (id, project, cwd, source, startedAt)
    }

    private func isFiltered(cwd: String, prompt: String) -> Bool {
        if builtInFiltersEnabled {
            let knownPaths = ["/.codex/memories", "/chronicle/screen_recording", "/.claude-mem"]
            let knownPrompts = ["## Memory Writing Agent", "# Overview Generate 0 to 3 hyperpersonalized suggestions", "Using the supplied git context below, generate", "What topic or area is the user exploring?"]
            if knownPaths.contains(where: cwd.contains) || knownPrompts.contains(where: prompt.hasPrefix) { return true }
        }
        let paths = pathFilters.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let prompts = promptFilters.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return paths.contains(where: cwd.contains) || prompts.contains(where: prompt.hasPrefix)
    }

    private func sessionTitle(at url: URL, fallback: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 1024 * 1024),
              let text = String(data: data, encoding: .utf8) else { return fallback }
        try? handle.close()
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]] else { continue }
            for item in content where item["type"] as? String == "input_text" {
                guard let value = item["text"] as? String else { continue }
                let clean = value.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let injected = clean.hasPrefix("<") || clean.hasPrefix("# Files mentioned")
                    || clean.hasPrefix("Distinguish instructions") || clean.hasPrefix("[App Context]")
                if !clean.isEmpty, !injected { return clean.count > 52 ? String(clean.prefix(52)) + "…" : clean }
            }
        }
        return fallback
    }

    private func sessionDetail(at url: URL, status: CodexIslandSession.Status) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else { return "正在工作" }
        try? handle.seek(toOffset: size > 96 * 1024 ? size - 96 * 1024 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if status == .completed {
                if type == "task_complete", let payload = object["payload"] as? [String: Any],
                   let message = payload["last_agent_message"] as? String {
                    let summary = message.split(separator: "\n").first.map(String.init)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !summary.isEmpty { return summary.count > 68 ? String(summary.prefix(68)) + "…" : summary }
                }
                if type == "event_msg", let payload = object["payload"] as? [String: Any],
                   payload["type"] as? String == "turn_aborted" { return "任务已停止" }
            }
            if type == "response_item", let payload = object["payload"] as? [String: Any] {
                if payload["type"] as? String == "custom_tool_call", let name = payload["name"] as? String {
                    return "正在执行 \(name)"
                }
                if payload["type"] as? String == "message" { return "正在整理结果" }
                if payload["type"] as? String == "reasoning" { return "正在分析" }
            }
        }
        return status == .completed ? "任务已完成" : "正在工作"
    }

    private func sessionStatus(at url: URL, modified: Date) -> CodexIslandSession.Status {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else {
            return Date().timeIntervalSince(modified) < 15 ? .running : .completed
        }
        try? handle.seek(toOffset: size > 128 * 1024 ? size - 128 * 1024 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = object["type"] as? String ?? ""
            let payloadType = (object["payload"] as? [String: Any])?["type"] as? String ?? ""
            if type == "task_complete" || payloadType == "task_complete" || payloadType == "turn_aborted" { return .completed }
            if payloadType == "task_started" { return .running }
        }
        return Date().timeIntervalSince(modified) < 15 ? .running : .completed
    }

    private func apply(_ event: CodexHookEvent) -> Bool {
        let normalized = event.event.lowercased()
        if normalized.contains("subagent"), !showSubagents { return false }
        let status: CodexIslandSession.Status
        if normalized.contains("permission") { status = .waiting }
        else if normalized.contains("stop") { status = .completed }
        else if normalized.contains("fail") || normalized.contains("error") { status = .failed }
        else { status = .running }

        let previousStatus = sessions.first(where: { $0.id == event.sessionID })?.status
        if let index = sessions.firstIndex(where: { $0.id == event.sessionID }) {
            sessions[index].project = event.project
            if !event.title.isEmpty { sessions[index].title = event.title }
            sessions[index].detail = event.detail
            sessions[index].status = status
            sessions[index].updatedAt = event.timestamp
        } else {
            sessions.append(CodexIslandSession(id: event.sessionID,
                                                project: event.project,
                                                title: event.title.isEmpty ? "Codex 任务" : event.title,
                                                detail: event.detail,
                                                status: status,
                                                startedAt: event.timestamp,
                                                updatedAt: event.timestamp))
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        let suppressSubagentNotice = normalized.contains("subagent") && subagentNotification == "main"
        if previousStatus != status, !suppressSubagentNotice {
            switch status {
            case .waiting: play(.waiting)
            case .completed: play(.completed)
            case .failed: play(.failed)
            case .running:
                if normalized.contains("session") || previousStatus == nil { play(.started) }
            }
        }
        return !suppressSubagentNotice && (status == .waiting || status == .completed || status == .failed)
    }

    func openCodex(_ session: CodexIslandSession? = nil) {
        if let session,
           let deepLink = URL(string: "codex://threads/\(session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id)"),
           NSWorkspace.shared.open(deepLink) { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    enum SoundKind { case started, completed, failed, waiting }

    func preview(_ kind: SoundKind) { play(kind, ignoresEnabled: true) }

    private func play(_ kind: SoundKind, ignoresEnabled: Bool = false) {
        guard ignoresEnabled || soundEnabled else { return }
        if !ignoresEnabled, muteWhileLocked,
           let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true { return }
        guard let sound = NSSound(data: Self.soundData(kind)) else { return }
        sound.stop()
        sound.volume = Float(min(max(soundVolume, 0.05), 1))
        sound.play()
    }

    static func soundData(_ kind: SoundKind) -> Data {
        let sampleRate = 44_100.0
        let notes: [(frequency: Double, start: Double, end: Double, gain: Double)]
        let accents: [(frequency: Double, start: Double, gain: Double)]
        switch kind {
        case .started:
            notes = [(392, 0, 0.28, 0.23), (523.25, 0.13, 0.43, 0.25), (659.25, 0.28, 0.62, 0.28)]
            accents = [(1567.98, 0.28, 0.13), (1975.53, 0.295, 0.06)]
        case .completed:
            notes = [(523.25, 0, 0.20, 0.25), (659.25, 0.09, 0.31, 0.27), (783.99, 0.19, 0.46, 0.30)]
            accents = [(1567.98, 0.19, 0.16), (2351.97, 0.205, 0.08)]
        case .failed:
            notes = [(659.25, 0, 0.25, 0.25), (523.25, 0.12, 0.39, 0.27), (392, 0.25, 0.58, 0.29)]
            accents = [(1318.51, 0, 0.12), (1046.50, 0.12, 0.08)]
        case .waiting:
            notes = [(523.25, 0, 0.22, 0.24), (659.25, 0.10, 0.35, 0.28),
                     (523.25, 0.39, 0.61, 0.25), (783.99, 0.49, 0.79, 0.30)]
            accents = [(1567.98, 0.10, 0.13), (1567.98, 0.49, 0.16), (2351.97, 0.505, 0.06)]
        }
        let duration = (notes.map(\.end).max() ?? 0.3) + 0.07
        let count = Int(sampleRate * duration)
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let time = Double(index) / sampleRate
            var value = 0.0
            for (frequency, start, end, gain) in notes where time >= start && time <= end {
                let local = time - start
                let length = end - start
                let attack = min(1, local / 0.025)
                let release = min(1, (length - local) / 0.12)
                let decay = exp(-2.2 * local / max(length, 0.01))
                let envelope = max(0, min(attack, release)) * decay
                value += sin(2 * .pi * frequency * local) * envelope * gain
                value += sin(2 * .pi * frequency * 2.005 * local) * envelope * gain * 0.11
            }
            for (frequency, start, gain) in accents where time >= start {
                let local = time - start
                if local < 0.12 {
                    let attack = min(1, local / 0.004)
                    let envelope = attack * exp(-28 * local)
                    value += sin(2 * .pi * frequency * local) * envelope * gain
                }
            }
            var sample = Int16(max(-1, min(1, value)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var data = Data("RIFF".utf8)
        appendUInt32(UInt32(36 + pcm.count), to: &data)
        data.append(Data("WAVEfmt ".utf8)); appendUInt32(16, to: &data); appendUInt16(1, to: &data); appendUInt16(1, to: &data)
        appendUInt32(UInt32(sampleRate), to: &data); appendUInt32(UInt32(sampleRate * 2), to: &data); appendUInt16(2, to: &data); appendUInt16(16, to: &data)
        data.append(Data("data".utf8)); appendUInt32(UInt32(pcm.count), to: &data); data.append(pcm)
        return data
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    private static func appendUInt32(_ value: UInt32, to data: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
}

enum CodexHookBridge {
    static let inboxDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vorssaint/CodexIsland/inbox", isDirectory: true)

    static func runAndExit() -> Never {
        autoreleasepool {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
            let baseEvent = string(in: object, keys: ["hook_event_name", "event", "event_name", "type"]) ?? "Update"
            let reportedStatus = string(in: object, keys: ["status", "result_status"])?.lowercased() ?? ""
            let event = reportedStatus == "failed" || reportedStatus == "error" ? "Failure" : baseEvent
            let sessionID = string(in: object, keys: ["session_id", "sessionId", "conversation_id", "thread_id"])
                ?? string(in: object, keys: ["transcript_path"]).map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "codex-default"
            let cwd = string(in: object, keys: ["cwd", "working_directory", "project_path"]) ?? ""
            let project = cwd.isEmpty ? "Codex" : URL(fileURLWithPath: cwd).lastPathComponent
            let prompt = string(in: object, keys: ["prompt", "user_prompt", "message"]) ?? ""
            let tool = string(in: object, keys: ["tool_name", "tool", "name"]) ?? ""
            let title = compact(prompt, fallback: project == "Codex" ? "Codex 任务" : project, limit: 52)
            let detail = eventDetail(event: event, tool: tool)
            let envelope = CodexHookEvent(event: event, sessionID: sessionID, project: project,
                                          title: title, detail: detail, timestamp: Date())
            do {
                try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
                let url = inboxDirectory.appendingPathComponent(String(format: "%.6f-%@.json", Date().timeIntervalSince1970, UUID().uuidString))
                try JSONEncoder.codexIsland.encode(envelope).write(to: url, options: .atomic)
            } catch { }
        }
        exit(0)
    }

    private static func eventDetail(event: String, tool: String) -> String {
        let value = event.lowercased()
        if value.contains("permission") { return "需要你的确认" }
        if value.contains("stop") { return "任务已完成" }
        if value.contains("sessionstart") || value.contains("session_start") { return "会话已开始" }
        if value.contains("prompt") { return "正在分析任务" }
        if value.contains("tool") { return tool.isEmpty ? "正在执行工具" : "正在执行 \(tool)" }
        return "正在工作"
    }

    private static func compact(_ value: String, fallback: String, limit: Int) -> String {
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = line.isEmpty ? fallback : line
        return source.count > limit ? String(source.prefix(limit)) + "…" : source
    }

    private static func string(in object: Any, keys: [String]) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = dictionary[key] as? String, !value.isEmpty { return value }
            }
            for value in dictionary.values {
                if let found = string(in: value, keys: keys) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = string(in: value, keys: keys) { return found }
            }
        }
        return nil
    }
}

private enum CodexHookInstaller {
    static let eventNames = ["PermissionRequest", "PostToolUse", "SessionStart", "Stop", "SubagentStop", "UserPromptSubmit"]
    static let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")

    static func install() throws {
        var root = try readRoot()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let command = "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' --vorssaint-codex-hook"
        for eventName in eventNames {
            var groups = hooks[eventName] as? [[String: Any]] ?? []
            let exists = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains("--vorssaint-codex-hook") == true
                } == true
            }
            if !exists {
                var group: [String: Any] = ["hooks": [["command": command, "timeout": 5, "type": "command"]]]
                if eventName == "PostToolUse" { group["matcher"] = "" }
                groups.append(group)
                hooks[eventName] = groups
            }
        }
        root["hooks"] = hooks
        try write(root)
    }

    static func uninstall() throws {
        var root = try readRoot()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for eventName in eventNames {
            let groups = hooks[eventName] as? [[String: Any]] ?? []
            let retained: [[String: Any]] = groups.compactMap { group -> [String: Any]? in
                var updated = group
                let commands = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    ($0["command"] as? String)?.contains("--vorssaint-codex-hook") != true
                }
                guard !commands.isEmpty else { return nil }
                updated["hooks"] = commands
                return updated
            }
            hooks[eventName] = retained
        }
        root["hooks"] = hooks
        try write(root)
    }

    private static func readRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [:] }
        let data = try Data(contentsOf: configURL)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var codexIsland: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}

private extension JSONDecoder {
    static var codexIsland: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
