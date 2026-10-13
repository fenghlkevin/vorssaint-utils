import AppKit
import CoreText
import Foundation
import SQLite3

/// Local Codex state, request-scoped approvals and optional Bark notifications.
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
    @Published private(set) var hookHealth: CodexHookHealth = .checking
    private var hookHealthCheckedAt = Date.distantPast
    private var hookHealthCheckInFlight = false
    @Published private(set) var lastError: String?
    @Published private(set) var approvalDestination = CodexHookBridge.approvalDestination
    @Published private(set) var approvals: [CodexIslandApproval] = []
    @Published private(set) var approvalFeedback: [String: String] = [:]
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

    private var completionGate = CodexCompletionGate()
    private var firstRefresh = true
    private var hookDirectories: [String: String] = [:]
    private var hookTargets: [String: (app: String?, tty: String?)] = [:]
    private let monitoringStartedAt = Calendar.current.startOfDay(for: Date())
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
        panelHeight = min(max(storedPanelHeight ?? 420, 220), 560)
        showSubagents = UserDefaults.standard.object(forKey: "dynamicIsland.codexShowSubagents") as? Bool ?? true
        subagentNotification = UserDefaults.standard.string(forKey: "dynamicIsland.codexSubagentNotification") ?? "main"
        builtInFiltersEnabled = UserDefaults.standard.object(forKey: "dynamicIsland.codexBuiltInFilters") as? Bool ?? true
        pathFilters = UserDefaults.standard.string(forKey: "dynamicIsland.codexPathFilters") ?? ""
        promptFilters = UserDefaults.standard.string(forKey: "dynamicIsland.codexPromptFilters") ?? ""
        if let fontURL = Bundle.main.url(forResource: "DepartureMono-Regular", withExtension: "otf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }

    var orderedSessions: [CodexIslandSession] { IslandSessionPresentation.ordered(sessions) }

    @Published var focusedNotificationSessionID: String?
    @Published var recentSessionsExpanded = false
    @Published private var presentationDate = Date()

    var panelPlan: IslandSessionPanelPlan {
        IslandSessionPanelPlan(sessions: enabled ? sessions : [], focusedID: focusedNotificationSessionID, now: presentationDate)
    }
    var displayedSessions: [CodexIslandSession] { panelPlan.primary }
    var activeSession: CodexIslandSession? { orderedSessions.first }
    var islandContentHeight: CGFloat {
        panelPlan.height(maximum: panelHeight, recentExpanded: recentSessionsExpanded, visibleRows: displayMode == "compact" ? 1 : 3)
    }
    func showAllSessions() { focusedNotificationSessionID = nil; recentSessionsExpanded = false }

    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }

    func approval(for session: CodexIslandSession) -> CodexIslandApproval? {
        approvals.first { $0.sessionID == session.id && $0.expiresAt > Date() }
    }

    func setApprovalDestination(_ destination: CodexApprovalDestination) {
        do {
            try CodexHookBridge.setApprovalDestination(destination)
            approvalDestination = destination
            lastError = nil
        } catch {
            lastError = "审批显示端保存失败，仍使用原来的设置。"
        }
    }

    func respondToApproval(for session: CodexIslandSession, requestID: String, allow: Bool) {
        guard approvalDestination == .island,
              let request = approval(for: session), request.id == requestID,
              approvalFeedback[requestID] == nil,
              let response = CodexHookSupport.responseURL(id: requestID, directory: CodexHookBridge.responseDirectory) else { return }
        do {
            try FileManager.default.createDirectory(at: CodexHookBridge.responseDirectory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            try (allow ? "allow" : "deny").write(to: response, atomically: true, encoding: .utf8)
            approvalFeedback[requestID] = allow ? "已发送允许，等待 Codex 接收" : "已发送拒绝，等待 Codex 接收"
            lastError = nil
        } catch { lastError = "审批发送失败，请重试或返回 Codex 处理。" }
    }

    private func notify(_ kind: IslandPhoneEvent, session: CodexIslandSession) {
        guard !firstRefresh, Date().timeIntervalSince(session.updatedAt) < 60 else { return }
        let filters = CodexIslandLogReader.Filters(builtIn: builtInFiltersEnabled, paths: pathFilters, prompts: promptFilters)
        guard !CodexIslandLogReader.isFiltered(cwd: hookDirectories[session.id] ?? "", prompt: session.title, filters: filters) else { return }
        IslandPhonePushService.shared.notify(kind, session: session)
    }

    func syncHookInstallation() {
        do {
            if enabled { try CodexHookInstaller.install() }
            else { try CodexHookInstaller.uninstall() }
            hookInstalled = enabled
            hookHealthCheckedAt = .distantPast
            lastError = nil
        } catch {
            hookInstalled = false
            lastError = error.localizedDescription
        }
    }

    func checkHookHealth() {
        guard enabled, !hookHealthCheckInFlight else { return }
        hookHealthCheckInFlight = true
        hookHealthCheckedAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let health = CodexHookHealth.inspect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.hookHealthCheckInFlight = false
                self.hookHealth = health
            }
        }
    }

    func refresh(includeSessionLogs: Bool = true) {
        // Snapshot UI-owned state before entering the serial I/O queue. A slow
        // directory scan must neither block scrolling nor enqueue more scans.
        guard enabled, !refreshInFlight else { return }
        refreshInFlight = true
        if Date().timeIntervalSince(hookHealthCheckedAt) >= 60 { checkHookHealth() }
        CodexHookBridge.updateHeartbeat()
        let expired = approvals.filter { $0.expiresAt <= Date() }
        for request in expired {
            approvals.removeAll { $0.id == request.id }
            approvalFeedback[request.id] = nil
            if let index = sessions.firstIndex(where: { $0.id == request.sessionID }), approval(for: sessions[index]) == nil {
                sessions[index].status = .running
                sessions[index].detail = "审批已过期，请返回 Codex 处理"
            }
        }
        let generation = refreshGeneration
        let currentSessions = sessions
        let startedAt = monitoringStartedAt
        let filters = CodexIslandLogReader.Filters(builtIn: builtInFiltersEnabled,
                                                  paths: pathFilters, prompts: promptFilters)
        let reader = logReader
        refreshQueue.async { [weak self] in
            let events = reader.readEvents(since: startedAt)
            let logs = includeSessionLogs ? reader.readSessions(previous: currentSessions, filters: filters, since: startedAt) : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard self.enabled, self.refreshGeneration == generation else { return }
                var attentionSessionID: String?
                self.presentationDate = Date()
                for event in events {
                    if self.apply(event), self.expandOnCompletion || self.sessions.first(where: { $0.id == event.sessionID })?.status != .completed {
                        attentionSessionID = event.sessionID
                    }
                }
                self.mergeSessionLogs(logs)
                let retained = self.sessions.filter {
                    $0.updatedAt >= self.monitoringStartedAt
                        && Date().timeIntervalSince($0.updatedAt) <= 6 * 60 * 60
                        && !CodexIslandLogReader.isFiltered(cwd: self.hookDirectories[$0.id] ?? "", prompt: $0.title, filters: filters)
                }
                if self.sessions != retained { self.sessions = retained }
                if let attentionSessionID, !self.firstRefresh {
                    let completed = self.sessions.first(where: { $0.id == attentionSessionID })?.status == .completed
                    if !completed || self.expandOnCompletion {
                        self.focusedNotificationSessionID = attentionSessionID
                        self.recentSessionsExpanded = false
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
            let confirmed = completionGate.accept(id: log.id, completed: log.status == .completed, now: Date())
            if !firstRefresh, !confirmed { continue }
            if let index = updated.firstIndex(where: { $0.id == log.id }) {
                let previous = updated[index]
                // Hooks applied after the scan began retain their authority.
                guard approval(for: previous) == nil,
                      previous.updatedAt <= log.updatedAt else { continue }
                updated[index] = log
                updated[index].startedAt = previous.startedAt
                if previous.status != log.status {
                    if log.status == .waiting { notify(.question, session: log) }
                    else if log.status == .failed { notify(.warning, session: log) }
                }
                if !firstRefresh, previous.status != .completed, log.status == .completed {
                    play(.completed)
                    notify(.completed, session: log)
                    if expandOnCompletion {
                        focusedNotificationSessionID = log.id
                        recentSessionsExpanded = false
                        DynamicIslandService.shared.activateCodex(duration: 4)
                    }
                } else if !firstRefresh, previous.status != .running, log.status == .running {
                    play(.started)
                }
            } else {
                updated.append(log)
                if log.status == .waiting { notify(.question, session: log) }
                if !firstRefresh, Date().timeIntervalSince(log.updatedAt) < 15 { play(.started) }
            }
        }
        updated.sort { $0.updatedAt > $1.updatedAt }
        if sessions != updated { sessions = updated }
    }

    private func apply(_ event: CodexHookEvent) -> Bool {
        // Stop hooks may precede automatic continuation. Let the enclosing
        // JSONL task/turn completion and stabilization gate decide completion.
        if ["Stop", "SessionEnd"].contains(event.event) { return false }
        if event.event == "PostToolUse", sessions.first(where: { $0.id == event.sessionID })?.status == .completed { return false }
        if event.event == "UserPromptSubmit" || event.event == "PermissionRequest" {
            _ = completionGate.accept(id: event.sessionID, completed: false, now: Date())
        }
        // Parent session IDs are used for sub-agent hooks. Never mark the parent complete.
        if event.event.hasPrefix("Subagent") {
            if showSubagents, let index = sessions.firstIndex(where: { $0.id == event.sessionID }) {
                sessions[index].detail = event.detail
            }
            return false
        }
        if ["Stop", "Interrupt", "SessionEnd"].contains(event.event) {
            let cancelled = approvals.filter { $0.sessionID == event.sessionID }
            for request in cancelled { approvalFeedback[request.id] = nil }
            approvals.removeAll { $0.sessionID == event.sessionID }
        }
        if let cwd = event.cwd { hookDirectories[event.sessionID] = cwd }
        if let app = event.terminalApp { hookTargets[event.sessionID] = (app, event.terminalTTY) }
        let filters = CodexIslandLogReader.Filters(builtIn: builtInFiltersEnabled, paths: pathFilters, prompts: promptFilters)
        let title = event.title.isEmpty ? (sessions.first { $0.id == event.sessionID }?.title ?? "") : event.title
        guard !CodexIslandLogReader.isFiltered(cwd: hookDirectories[event.sessionID] ?? "", prompt: title, filters: filters) else { return false }
        // Keep navigation metadata, but do not create tasks for CLI startup/shutdown.
        if event.event == "SessionStart" { return false }
        if ["SessionEnd", "Stop", "Interrupt"].contains(event.event),
           !sessions.contains(where: { $0.id == event.sessionID }) { return false }
        let isResolution = event.event == "ApprovalResolved" || event.event == "ApprovalExpired" || event.event == "ApprovalHandedOff"
        if isResolution, let requestID = event.approvalID {
            guard approvals.contains(where: { $0.id == requestID }) else { return false }
            approvals.removeAll { $0.id == requestID }
            approvalFeedback[requestID] = nil
            if !approvals.contains(where: { $0.sessionID == event.sessionID }) {
            }
        }
        let status: CodexIslandSession.Status
        switch event.event {
        case "PermissionRequest":
            guard approvalDestination == .island else { return false }
            guard let id = event.approvalID, UUID(uuidString: id) != nil,
                  let deadline = event.approvalExpiresAt, deadline > Date() else { return false }
            if !approvals.contains(where: { $0.id == id }) {
                approvals.append(.init(id: id, sessionID: event.sessionID, operation: event.operation ?? event.detail, expiresAt: deadline))
            }
            status = .waiting
        case "Stop", "Interrupt", "SessionEnd": status = .completed
        case "Failure", "Error": status = .failed
        default: status = .running
        }
        let previousStatus = sessions.first(where: { $0.id == event.sessionID })?.status
        if let index = sessions.firstIndex(where: { $0.id == event.sessionID }) {
            if sessions[index].updatedAt > event.timestamp, !isResolution, event.event != "PermissionRequest" { return false }
            sessions[index].project = event.project
            if !event.title.isEmpty { sessions[index].title = event.title }
            sessions[index].detail = event.detail
            sessions[index].status = status
            sessions[index].updatedAt = event.timestamp
        } else {
            sessions.append(CodexIslandSession(id: event.sessionID, project: event.project,
                                               title: event.title.isEmpty ? event.project : event.title,
                                               detail: event.detail, status: status,
                                               startedAt: event.timestamp, updatedAt: event.timestamp))
        }
        if let index = sessions.firstIndex(where: { $0.id == event.sessionID }) {
            if let remaining = approval(for: sessions[index]) {
                sessions[index].status = .waiting
                sessions[index].detail = remaining.operation
            }
            let session = sessions[index]
            if event.event == "PermissionRequest" { notify(.approval, session: session) }
            else if previousStatus != status && status == .completed && event.event == "Stop" { notify(.completed, session: session) }
            else if previousStatus != status && status == .failed { notify(.warning, session: session) }
            else if event.event == "Interrupt" { notify(.warning, session: session) }
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if previousStatus != status {
            switch status {
            case .waiting: play(.waiting)
            case .completed: play(.completed)
            case .failed: play(.failed)
            case .running: if previousStatus == nil { play(.started) }
            }
        }
        return status == .waiting || status == .completed || status == .failed
    }

    func openCodex(_ session: CodexIslandSession? = nil) {
        if let session, let target = hookTargets[session.id], target.app == "Apple_Terminal",
           let tty = target.tty, tty.hasPrefix("/dev/ttys"),
           tty.dropFirst(9).allSatisfy({ $0.isNumber }) {
            let script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
            DispatchQueue.global(qos: .userInitiated).async { _ = AppleScriptRunner.runDetailed(script) }
            return
        }
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
    private static var storageRoot: URL {
        #if VORSSAINT_TESTING
        if let path = ProcessInfo.processInfo.environment["VORSSAINT_ISLAND_TEST_ROOT"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vorssaint/CodexIsland", isDirectory: true)
    }
    static var approvalDestination: CodexApprovalDestination {
        guard let value = try? String(contentsOf: storageRoot.appendingPathComponent("approval-destination"), encoding: .utf8),
              let destination = CodexApprovalDestination(rawValue: value) else { return .island }
        return destination
    }
    static func setApprovalDestination(_ destination: CodexApprovalDestination) throws {
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try destination.rawValue.write(to: storageRoot.appendingPathComponent("approval-destination"), atomically: true, encoding: .utf8)
    }

    static var inboxDirectory: URL { storageRoot.appendingPathComponent("inbox", isDirectory: true) }
    static var responseDirectory: URL { storageRoot.appendingPathComponent("responses", isDirectory: true) }

    static let heartbeatURL = inboxDirectory.deletingLastPathComponent().appendingPathComponent("heartbeat")

    static func updateHeartbeat() {
        try? FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data().write(to: heartbeatURL, options: .atomic)
    }
    private static var receiverIsAlive: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: heartbeatURL.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < 8
    }
    private static func publish(_ event: CodexHookEvent) throws {
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = inboxDirectory.appendingPathComponent(String(format: "%.6f-%@.json", Date().timeIntervalSince1970, UUID().uuidString))
        try JSONEncoder.codexIsland.encode(event).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func runAndExit() -> Never {
        autoreleasepool {
            // No running receiver: leave Codex's own approval flow in charge immediately.
            guard receiverIsAlive else { exit(0) }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard var event = try? CodexHookSupport.decode(input, environment: ProcessInfo.processInfo.environment) else { exit(0) }
            if event.event == "PermissionRequest", approvalDestination == .codex { exit(0) }
            do { try publish(event) } catch { exit(0) }
            guard let requestID = event.approvalID,
                  let responseURL = CodexHookSupport.responseURL(id: requestID, directory: responseDirectory),
                  let deadline = event.approvalExpiresAt else { exit(0) }
            defer { try? FileManager.default.removeItem(at: responseURL) }
            while Date() < deadline && receiverIsAlive {
                if approvalDestination == .codex {
                    event.event = "ApprovalHandedOff"
                    event.detail = "已交由 Codex 审批"
                    event.timestamp = Date()
                    try? publish(event)
                    return
                }
                if let decision = try? String(contentsOf: responseURL, encoding: .utf8),
                   let output = try? CodexHookSupport.response(decision) {
                    FileHandle.standardOutput.write(output)
                    event.event = "ApprovalResolved"
                    event.detail = decision == "allow" ? "Codex 已接收允许" : "Codex 已接收拒绝"
                    event.timestamp = Date()
                    try? publish(event)
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            event.event = "ApprovalExpired"
            event.detail = "审批已过期，请返回 Codex 处理"
            event.timestamp = Date()
            try? publish(event)
        }
        exit(0)
    }
}

private enum CodexHookInstaller {
    static let eventNames = ["PermissionRequest", "PostToolUse", "SessionStart", "SessionEnd", "Interrupt", "Stop", "SubagentStart", "SubagentStop", "UserPromptSubmit"]
    static let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")

    static func install() throws {
        var root = try readRoot()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let command = "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' --vorssaint-codex-hook"
        for eventName in eventNames {
            var groups = hooks[eventName] as? [[String: Any]] ?? []
            let timeout = eventName == "PermissionRequest" ? 300 : (["SessionEnd", "Interrupt"].contains(eventName) ? 3 : 5)
            var exists = false
            groups = groups.map { group in
                var updated = group
                var entries = group["hooks"] as? [[String: Any]] ?? []
                entries = entries.map { entry in
                    guard (entry["command"] as? String)?.contains("--vorssaint-codex-hook") == true else { return entry }
                    exists = true
                    var updatedEntry = entry
                    updatedEntry["command"] = command
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
    private var cursors: [URL: CodexIncrementalLog] = [:]
    private typealias Metadata = (id: String, project: String, cwd: String, threadSource: String, startedAt: Date)
    private var metadataCache: [URL: Metadata] = [:]
    private var logsWithTasks = Set<URL>()
    private var questionTrackers: [URL: CodexQuestionTracker] = [:]
    private var statusCache: [URL: CodexIslandSession.Status] = [:]
    private var detailCache: [URL: String] = [:]
    private var incomingObjects: [URL: [[String: Any]]] = [:]
    private var cachedThreadTitles: [String: String] = [:]
    private var titlesReadAt: Date?

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
        let active = Set(candidates.map { $0.0 })
        cursors = cursors.filter { active.contains($0.key) }
        logsWithTasks.formIntersection(active)
        metadataCache = metadataCache.filter { active.contains($0.key) }
        questionTrackers = questionTrackers.filter { active.contains($0.key) }
        statusCache = statusCache.filter { active.contains($0.key) }
        detailCache = detailCache.filter { active.contains($0.key) }
        logTitles = logTitles.filter { active.contains(URL(fileURLWithPath: $0.key)) }
        incomingObjects.removeAll(keepingCapacity: true)
        defer { incomingObjects.removeAll(keepingCapacity: true) }
        let titles = currentCodexThreadTitles()
        var result: [CodexIslandSession] = []
        for (url, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard result.count < 8 else { break }
            let cursor = cursors[url] ?? CodexIncrementalLog()
            cursors[url] = cursor
            guard let batch = try? cursor.read(url) else { continue }
            if batch.reset {
                logsWithTasks.remove(url)
                metadataCache[url] = nil
                questionTrackers[url] = nil
                statusCache[url] = nil
                detailCache[url] = nil
                logTitles[url.path] = nil
            }
            guard let metadata = metadataCache[url] ?? sessionMetadata(at: url) else { continue }
            metadataCache[url] = metadata
            guard metadata.threadSource == "user" else { continue }
            if CodexTaskActivity.containsTask(batch.objects) { logsWithTasks.insert(url) }
            guard logsWithTasks.contains(url) else { continue }
            incomingObjects[url] = batch.objects
            let previousSession = previous.first { $0.id == metadata.id }
            let title = titles[metadata.id] ?? logTitles[url.path] ?? sessionTitle(at: url, fallback: metadata.project)
            guard !Self.isFiltered(cwd: metadata.cwd, prompt: title, filters: filters) else { continue }
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
        let now = Date()
        if let titlesReadAt, now.timeIntervalSince(titlesReadAt) < 15 { return cachedThreadTitles }
        titlesReadAt = now
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return [:] }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''))
            FROM threads
            WHERE updated_at >= CAST(strftime('%s', 'now') AS INTEGER) - 21600
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
        cachedThreadTitles = titles
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
                  now.timeIntervalSince(modified) < 6 * 60 * 60 else { return }
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
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let newline = data.firstIndex(of: 10),
              let object = try? JSONSerialization.jsonObject(with: Data(data[..<newline])) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        let source: String
        if let value = payload["thread_source"] as? String { source = value }
        else if let value = payload["source"] as? String, ["cli", "vscode", "exec", "app"].contains(value) { source = "user" }
        else { source = "" }
        let id = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? url.lastPathComponent
        let cwd = payload["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Codex" : URL(fileURLWithPath: cwd).lastPathComponent
        let startedAt = ISO8601DateFormatter().date(from: payload["timestamp"] as? String ?? "") ?? Date()
        return (id, project, cwd, source, startedAt)
    }

    static func isFiltered(cwd: String, prompt: String, filters: Filters) -> Bool {
        if filters.builtIn {
            let knownPaths = ["/.codex/memories", "/chronicle/screen_recording", "/.claude-mem"]
            // Titles extracted from logs are limited to 52 characters, so
            // match the stable prefix of Codex's background suggestion request.
            let knownPrompts = ["## Memory Writing Agent", "# Overview Generate 0 to 3 hyperpersonalized suggestions", "Using the supplied git context below, generate", "What topic or area is the user exploring?", "This is an app-generated request for a suggested"]
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
        if let prompt = questionTrackers[url]?.prompt { return prompt }
        if let detail = newSessionDetail(at: url, status: status) { detailCache[url] = detail }
        return detailCache[url] ?? (status == .completed ? "任务已完成" : "正在工作")
    }

    private func newSessionDetail(at url: URL, status: CodexIslandSession.Status) -> String? {
        for object in (incomingObjects[url] ?? []).reversed() {
            guard let type = object["type"] as? String else { continue }
            if status == .failed, let payload = object["payload"] as? [String: Any] {
                return String(((payload["message"] as? String) ?? "任务执行失败").prefix(1000))
            }
            if status == .completed {
                if let payload = object["payload"] as? [String: Any],
                   type == "task_complete" || payload["type"] as? String == "task_complete",
                   let message = payload["last_agent_message"] as? String {
                    let summary = message.split(separator: "\n").first.map(String.init)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !summary.isEmpty { return summary.count > 68 ? String(summary.prefix(68)) + "…" : summary }
                }
                if type == "event_msg", let payload = object["payload"] as? [String: Any],
                   payload["type"] as? String == "turn_aborted" { return "任务已停止" }
            }
            if type == "response_item", let payload = object["payload"] as? [String: Any] {
                if status == .completed, payload["role"] as? String == "assistant",
                   payload["phase"] as? String == "final_answer", let content = payload["content"] as? [[String: Any]] {
                    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { return String(text.prefix(1000)) }
                }
                if payload["type"] as? String == "custom_tool_call", let name = payload["name"] as? String {
                    return "正在执行 \(name)"
                }
                if payload["type"] as? String == "message" { return "正在整理结果" }
                if payload["type"] as? String == "reasoning" { return "正在分析" }
            }
        }
        return nil
    }

    private func sessionStatus(at url: URL, modified: Date,
                               previousStatus: CodexIslandSession.Status?) -> CodexIslandSession.Status {
        var latestStatus = statusCache[url]
        var questions = questionTrackers[url] ?? CodexQuestionTracker()
        let previouslyAsked = questions.callID != nil
        for object in incomingObjects[url] ?? [] {
            questions.apply(object)
            if let event = CodexLogLifecycleState.event(in: object) {
                latestStatus = CodexIslandSession.Status(rawValue: event.rawValue)
            }
        }
        questionTrackers[url] = questions
        if questions.callID != nil { return .waiting }
        if previouslyAsked, latestStatus == nil { latestStatus = .running }
        if let latestStatus {
            if statusCache[url] != latestStatus { detailCache[url] = nil }
            statusCache[url] = latestStatus
            return latestStatus
        }
        // A quiet task is not necessarily complete: long reasoning and tool
        // calls can leave the JSONL unchanged for well over 15 seconds. Keep
        // the last known state until Codex writes an explicit lifecycle event.
        return previousStatus ?? (Date().timeIntervalSince(modified) < 6 * 60 * 60 ? .running : .completed)
    }

}

private extension JSONEncoder {
    static var codexIsland: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}

private extension JSONDecoder {
    static var codexIsland: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
