import AppKit
import CoreText
import Foundation
import SQLite3

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
    let approvalID: String?
}

/// Receives small, local-only state envelopes written by the Codex hook
/// subprocess. Full prompts, tool inputs and transcripts are never persisted.
final class CodexIslandService: ObservableObject {
    static let shared = CodexIslandService()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: DefaultsKey.dynamicIslandCodexEnabled)
            refreshGeneration = UUID()
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

    private var firstRefresh = true
    private let monitoringStartedAt = Date()
    private let refreshQueue = DispatchQueue(label: "Vorssaint.codexIsland.refresh", qos: .utility)
    private let logReader = CodexIslandLogReader()
    private var refreshInFlight = false
    private var refreshGeneration = UUID()

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

    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }

    func respondToApproval(for session: CodexIslandSession, allow: Bool) {
        let directory = CodexHookBridge.responseDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let response = directory.appendingPathComponent(session.id + ".response")
        try? (allow ? "allow" : "deny").write(to: response, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func submit(_ prompt: String, to session: CodexIslandSession) -> Bool {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".npm-global/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            lastError = "找不到 Codex 命令行工具"
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["exec", "resume", "--all", session.id, clean]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); return true } catch { lastError = error.localizedDescription; return false }
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
        // Snapshot UI-owned state before entering the serial I/O queue. A slow
        // directory scan must neither block scrolling nor enqueue more scans.
        guard enabled, !refreshInFlight else { return }
        refreshInFlight = true
        let generation = refreshGeneration
        let currentSessions = sessions
        let startedAt = monitoringStartedAt
        let filters = CodexIslandLogReader.Filters(builtIn: builtInFiltersEnabled,
                                                  paths: pathFilters, prompts: promptFilters)
        let reader = logReader
        refreshQueue.async { [weak self] in
            let events = reader.readEvents(since: startedAt)
            let logs = reader.readSessions(previous: currentSessions, filters: filters, since: startedAt)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard self.enabled, self.refreshGeneration == generation else { return }
                var attention = false
                for event in events { attention = self.apply(event) || attention }
                self.mergeSessionLogs(logs)
                let retained = self.sessions.filter { Date().timeIntervalSince($0.updatedAt) <= 2 * 60 * 60 }
                if self.sessions != retained { self.sessions = retained }
                if attention, !self.firstRefresh {
                    let completed = self.sessions.first?.status == .completed
                    if !completed || self.expandOnCompletion {
                        DynamicIslandService.shared.activateCodex(duration: completed ? 4 : 5)
                    }
                }
                self.firstRefresh = false
            }
        }
    }

    private func mergeSessionLogs(_ logs: [CodexIslandSession]) {
        var updated = sessions
        for log in logs {
            if let index = updated.firstIndex(where: { $0.id == log.id }) {
                let previous = updated[index]
                // Hooks applied after the scan began retain their authority.
                guard !(previous.status == .waiting && Date().timeIntervalSince(previous.updatedAt) < 5 * 60),
                      previous.updatedAt <= log.updatedAt else { continue }
                updated[index] = log
                updated[index].startedAt = previous.startedAt
                if !firstRefresh, previous.status == .running, log.status == .completed {
                    play(.completed)
                    if expandOnCompletion { DynamicIslandService.shared.activateCodex(duration: 4) }
                } else if !firstRefresh, previous.status != .running, log.status == .running {
                    play(.started)
                }
            } else {
                updated.append(log)
                if !firstRefresh, Date().timeIntervalSince(log.updatedAt) < 15 { play(.started) }
            }
        }
        updated.sort { $0.updatedAt > $1.updatedAt }
        if sessions != updated { sessions = updated }
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
    static let responseDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vorssaint/CodexIsland/responses", isDirectory: true)

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
            let approvalID = baseEvent.lowercased().contains("permission") ? sessionID : nil
            if approvalID != nil {
                try? FileManager.default.createDirectory(at: responseDirectory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: responseDirectory.appendingPathComponent(sessionID + ".response"))
            }
            let envelope = CodexHookEvent(event: event, sessionID: sessionID, project: project,
                                          title: title, detail: detail, timestamp: Date(), approvalID: approvalID)
            do {
                try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
                let url = inboxDirectory.appendingPathComponent(String(format: "%.6f-%@.json", Date().timeIntervalSince1970, UUID().uuidString))
                try JSONEncoder.codexIsland.encode(envelope).write(to: url, options: .atomic)
            } catch { }
            if approvalID != nil {
                let responseURL = responseDirectory.appendingPathComponent(sessionID + ".response")
                let deadline = Date().addingTimeInterval(295)
                while Date() < deadline {
                    if let decision = try? String(contentsOf: responseURL, encoding: .utf8) {
                        try? FileManager.default.removeItem(at: responseURL)
                        let behavior = decision == "allow" ? "allow" : "deny"
                        let output: [String: Any] = ["hookSpecificOutput": [
                            "hookEventName": "PermissionRequest",
                            "decision": ["behavior": behavior]
                        ]]
                        if let data = try? JSONSerialization.data(withJSONObject: output) {
                            FileHandle.standardOutput.write(data)
                        }
                        exit(0)
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
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
            let timeout = eventName == "PermissionRequest" ? 300 : 5
            var exists = false
            groups = groups.map { group in
                var updated = group
                var entries = group["hooks"] as? [[String: Any]] ?? []
                entries = entries.map { entry in
                    guard (entry["command"] as? String)?.contains("--vorssaint-codex-hook") == true else { return entry }
                    exists = true
                    var updatedEntry = entry
                    updatedEntry["timeout"] = timeout
                    return updatedEntry
                }
                updated["hooks"] = entries
                return updated
            }
            if !exists {
                var group: [String: Any] = ["hooks": [["command": command, "timeout": timeout, "type": "command"]]]
                if eventName == "PostToolUse" { group["matcher"] = "" }
                groups.append(group)
                hooks[eventName] = groups
            }
            if exists { hooks[eventName] = groups }
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

/// All mutable caches and filesystem/database reads are confined to refreshQueue.
private final class CodexIslandLogReader {
    struct Filters {
        let builtIn: Bool
        let paths: String
        let prompts: String
    }

    private var consumedFiles = Set<String>()
    private var logTitles: [String: String] = [:]
    private var recentlyDiscoveredLogs = Set<URL>()
    private var lastFullLogDiscoveryAt: Date?
    private var monitoringStartedAt = Date()

    func readEvents(since startedAt: Date) -> [CodexHookEvent] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: CodexHookBridge.inboxDirectory,
                                                includingPropertiesForKeys: nil)) ?? []
        var events: [CodexHookEvent] = []
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard consumedFiles.insert(url.lastPathComponent).inserted else { continue }
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let event = try? JSONDecoder.codexIsland.decode(CodexHookEvent.self, from: data),
                  event.timestamp >= startedAt else { continue }
            events.append(event)
        }
        return events
    }

    func readSessions(previous: [CodexIslandSession], filters: Filters, since startedAt: Date) -> [CodexIslandSession] {
        monitoringStartedAt = startedAt
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let candidates = recentSessionLogCandidates(in: root)
        let titles = currentCodexThreadTitles()
        var result: [CodexIslandSession] = []
        for (url, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard result.count < 8 else { break }
            guard let metadata = sessionMetadata(at: url), metadata.threadSource == "user" else { continue }
            let previousSession = previous.first { $0.id == metadata.id }
            if let previousSession, previousSession.status == .waiting,
               Date().timeIntervalSince(previousSession.updatedAt) < 5 * 60 { continue }
            let title = titles[metadata.id] ?? logTitles[url.path] ?? sessionTitle(at: url, fallback: metadata.project)
            guard !isFiltered(cwd: metadata.cwd, prompt: title, filters: filters) else { continue }
            logTitles[url.path] = title
            let status = sessionStatus(at: url, modified: modified, previousStatus: previousSession?.status)
            result.append(CodexIslandSession(id: metadata.id, project: metadata.project, title: title,
                                            detail: sessionDetail(at: url, status: status), status: status,
                                            startedAt: metadata.startedAt, updatedAt: modified))
        }
        return result
    }

    /// Codex stores the user-facing sidebar label in `threads.name`. The
    /// JSONL stream only contains prompts, so it cannot reproduce generated
    /// or manually renamed session titles accurately.
    private func currentCodexThreadTitles() -> [String: String] {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return [:] }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''))
            FROM threads
            WHERE updated_at >= CAST(strftime('%s', 'now') AS INTEGER) - 7200
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }

        var titles: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(statement, 0),
                  let titleBytes = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: idBytes)
            let title = String(cString: titleBytes).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titles[id] = title }
        }
        return titles
    }

    /// A task keeps the directory of the day it was created, even when it is
    /// still running days later. Discover by file modification time instead
    /// of assuming every live task lives under today's directory.
    private func recentSessionLogCandidates(in root: URL) -> [(URL, Date)] {
        let now = Date()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var modifiedByURL: [URL: Date] = [:]

        func collect(_ url: URL) {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= monitoringStartedAt,
                  now.timeIntervalSince(modified) < 2 * 60 * 60 else { return }
            modifiedByURL[url] = modified
        }

        // Today's and yesterday's folders are cheap to inspect every second,
        // which keeps newly-created tasks responsive.
        let calendar = Calendar.current
        for offset in 0...1 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                           includingPropertiesForKeys: Array(keys)) else { continue }
            files.forEach(collect)
        }

        // A full walk catches a task resumed from an older date folder. Keep
        // the recent hits warm between walks so the one-second refresh remains
        // cheap while that task is active.
        if lastFullLogDiscoveryAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            let enumerator = fm.enumerator(at: root,
                                           includingPropertiesForKeys: Array(keys),
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                collect(url)
            }
            recentlyDiscoveredLogs = Set(modifiedByURL.keys)
            lastFullLogDiscoveryAt = now
        } else {
            recentlyDiscoveredLogs.forEach(collect)
        }
        recentlyDiscoveredLogs = recentlyDiscoveredLogs.filter { modifiedByURL[$0] != nil }
        return modifiedByURL.map { ($0.key, $0.value) }
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

    private func isFiltered(cwd: String, prompt: String, filters: Filters) -> Bool {
        if filters.builtIn {
            let knownPaths = ["/.codex/memories", "/chronicle/screen_recording", "/.claude-mem"]
            let knownPrompts = ["## Memory Writing Agent", "# Overview Generate 0 to 3 hyperpersonalized suggestions", "Using the supplied git context below, generate", "What topic or area is the user exploring?"]
            if knownPaths.contains(where: cwd.contains) || knownPrompts.contains(where: prompt.hasPrefix) { return true }
        }
        let paths = filters.paths.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let prompts = filters.prompts.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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

    private func sessionStatus(at url: URL, modified: Date,
                               previousStatus: CodexIslandSession.Status?) -> CodexIslandSession.Status {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else {
            return previousStatus ?? .running
        }
        try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        let text = String(data: data, encoding: .utf8) ?? ""
        var latestStatus: CodexIslandSession.Status?
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = object["type"] as? String ?? ""
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String ?? ""
            if payloadType == "task_started" {
                latestStatus = .running
                continue
            }
            if type == "task_complete" || payloadType == "task_complete"
                || payloadType == "turn_complete" || payloadType == "turn_completed"
                || payloadType == "turn_aborted" {
                latestStatus = .completed
                continue
            }
            // The desktop app renders the final answer before its trailing
            // task_complete event is flushed. Treat that final answer as the
            // end of the current turn so the island changes immediately.
            if type == "event_msg", payloadType == "item_completed",
               let item = payload?["item"] as? [String: Any],
               item["type"] as? String == "AgentMessage",
               item["phase"] as? String == "final_answer" {
                latestStatus = .completed
                continue
            }
            if type == "response_item", payloadType == "message",
               payload?["role"] as? String == "assistant",
               payload?["phase"] as? String == "final_answer" {
                latestStatus = .completed
            }
        }
        if let latestStatus { return latestStatus }
        // A quiet task is not necessarily complete: long reasoning and tool
        // calls can leave the JSONL unchanged for well over 15 seconds. Keep
        // the last known state until Codex writes an explicit lifecycle event.
        return previousStatus ?? (Date().timeIntervalSince(modified) < 2 * 60 * 60 ? .running : .completed)
    }

}

private extension JSONEncoder {
    static var codexIsland: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}

private extension JSONDecoder {
    static var codexIsland: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
