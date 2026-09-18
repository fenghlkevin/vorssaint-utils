// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import AppKit
import Combine
import Foundation
import Security
import Darwin

@MainActor
final class ProxyService: ObservableObject {
    enum State { case stopped, starting, running, stopping, failed }
    private static var instance: ProxyService?
    static var shared: ProxyService {
        if let instance { return instance }
        let created = ProxyService(); instance = created; return created
    }
    static var loaded: ProxyService? { instance }
    static func recoverAtLaunchIfDisabled() {
        guard !AppFeature.networkProxy.isAvailable, let base = PrivateFileStore.containerURL,
              FileManager.default.fileExists(atPath: base.appendingPathComponent("Proxy/system-proxy.plist").path) else { return }
        shared.featureEnabled = false
        shared.recoverIfNeeded()
    }
    @Published private(set) var state: State = .stopped
    @Published private(set) var busy = false
    @Published private(set) var profiles: [ProxyProfile] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var preferences = ProxyPreferences()
    @Published private(set) var inspection: ProxyInspection?
    @Published private(set) var groups: [ProxyGroup] = []
    @Published private(set) var delays: [String: Int] = [:]
    @Published private(set) var testingNodes: Set<String> = []
    @Published private(set) var delayDates: [String: Date] = [:]
    private var delayTask: Task<Void, Never>?
    private var delayGeneration = UUID()
    @Published private(set) var error: String?
    @Published private(set) var statusDetail = ""
    @Published private(set) var systemProxyEffective = false
    @Published private(set) var tunnelEffective = false
    @Published private(set) var tunnelStatus = "未启用"
    @Published private(set) var tunnelAccess = "未安装"
    @Published private(set) var networkChecks: [ProxyNetworkCheck] = []
    @Published private(set) var tunnelPreview = ""
    private let tunnelClient = ProxyTunnelClient()
    private let systemClient = ProxySystemClient()
    private var systemHelperSession = false
    private var preferSystemHelper = false
    private var tunnelSession = false
    private var sleepObserver: NSObjectProtocol?

    @Published var editorYAML = ""
    @Published var editorOverrides = ""
    @Published private(set) var editorSaved = ProxyDraft(yaml: "")
    @Published private(set) var revisionHistory: [ProxyRevision] = []
    @Published private(set) var draftReport: [ProxyIssue] = []
    @Published private(set) var draftDiff = ""
    @Published private(set) var resourceStates: [ProxyResourceState] = []
    private var activeWork: URL?
    var editorDirty: Bool { ProxyDraft(yaml: editorYAML, overrides: editorOverrides) != editorSaved }
    @Published var importPreview: ProxyInspection?
    @Published var importName = ""
    @Published var confirmRepairs = false
    private var importData: Data?
    let telemetry: ProxyTelemetry
    private let store: ProxyProfileStore
    private let coreExecutableURL: URL
    private let coreManifestURL: URL
    private let guardianExecutableURL: URL
    private let guardian = ProxyGuardianClient()
    private var api: ProxyAPI?
    private var operation: Task<Void, Never>?
    private var shutdownTask: Task<Bool, Never>?
    private var monitoring: Task<Void, Never>?
    private var startupAttempted = false
    private var featureEnabled = true
    var selectedProfile: ProxyProfile? { profiles.first { $0.id == selectedID } }
    var canStart: Bool { !busy && selectedID != nil && inspection?.hasErrors == false && state == .stopped }
    var stateText: String {
        switch state { case .stopped: return "已停止"; case .starting: return "正在准备"; case .running: return "运行中"; case .stopping: return "正在恢复网络"; case .failed: return "需要处理" }
    }
    var guardianExecutable: URL { guardianExecutableURL }
    init(root: URL? = nil, core: URL? = nil, guardian: URL? = nil) {
        coreExecutableURL = core ?? ProxyCore.executable
        coreManifestURL = (core ?? ProxyCore.executable).deletingLastPathComponent().appendingPathComponent("manifest.json")
        guardianExecutableURL = guardian ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VorssaintProxyGuardian")
        let base = PrivateFileStore.containerURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("VorssaintProxyUnavailable")
        store = ProxyProfileStore(root: root ?? base.appendingPathComponent("Proxy", isDirectory: true))
        telemetry = ProxyTelemetry(root: store.root)
        do {
            try store.recoverApply()
            profiles = try store.profiles(); preferences = try store.loadPreferences()
            if let data = try? Data(contentsOf: store.root.appendingPathComponent("selected-profile.json")) { selectedID = try? JSONDecoder().decode(UUID.self, from: data) }
            if !profiles.contains(where: { $0.id == selectedID }) { selectedID = profiles.first?.id }
            try loadInspection()
        } catch { self.error = error.localizedDescription }
        systemClient.onStatus = { [weak self] active, message in
            guard let self else { return }
            self.systemProxyEffective = active
            if !message.isEmpty { self.error = message }
        }
        systemClient.onFailure = { [weak self] message in
            guard let self, self.systemHelperSession else { return }
            self.systemProxyEffective = false; self.error = message
            Task { _ = await self.stopAndWait(); self.error = message }
        }
        tunnelAccess = tunnelClient.accessText
        tunnelClient.onStatus = { [weak self] reply in
            guard let self else { return }
            self.tunnelEffective = reply.active
            self.tunnelStatus = reply.active ? "\(reply.interface ?? "TUN") · \(reply.routeCount) 条自有路由" : (reply.message.isEmpty ? "未接管" : reply.message)
            if !reply.message.isEmpty { self.error = reply.message }
        }
        tunnelClient.onFailure = { [weak self] message in
            guard let self, self.tunnelSession else { return }
            self.tunnelEffective = false; self.error = message
            if self.state == .running { Task { _ = await self.stopAndWait(); self.error = message } }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tunnelSession else { return }
                _ = await self.stopAndWait()
                self.tunnelStatus = "休眠前已停止增强模式；唤醒后请手动启动。"
            }
        }
        self.guardian.onEvent = { [weak self] event in
            guard let self else { return }
            if !self.systemHelperSession { self.systemProxyEffective = event.systemProxy }
            if ["fault", "network", "guardian-exit"].contains(event.identifier), self.state == .running {
                self.error = event.message
                if event.corePID == nil { self.state = .failed; self.monitoring?.cancel(); self.telemetry.stop(); self.telemetry.addLog(level: "error", message: event.message); self.api = nil; if self.systemHelperSession { Task { do { try await self.systemClient.stop(); self.systemHelperSession = false; self.systemProxyEffective = false } catch { self.error = error.localizedDescription } } }; if self.tunnelSession { Task { do { try await self.tunnelClient.stop(); self.tunnelEffective = false; self.tunnelSession = false } catch { self.error = error.localizedDescription } } } }
            }
        }
    }
    private func loadInspection() throws {
        if let selectedID { inspection = try ProxyConfigCompiler.inspect(try store.committed(selectedID).effective()) }
        else { inspection = nil }
        if state != .running { groups = inspection?.groups ?? [] }
        try loadEditor()
    }
    func sync(enabled: Bool) {
        featureEnabled = enabled
        if !enabled { Task { _ = await stopAndWait() }; return }
        guard !startupAttempted else { return }; startupAttempted = true
        if preferences.autoStart && canStart { start() }
        else { recoverIfNeeded() }
    }
    func recoverIfNeeded() {
        guard !busy, FileManager.default.fileExists(atPath: store.root.appendingPathComponent("system-proxy.plist").path) else { return }
        run {
            try self.guardian.launch(executable: self.guardianExecutable, root: self.store.root)
            _ = try await self.guardian.send(.init(command: "recover"))
            self.statusDetail = "已核对上次的系统代理恢复记录。"
        }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await work() }
            catch is CancellationError { self.statusDetail = "操作已取消。" }
            catch { self.error = error.localizedDescription }
        }
    }
    func chooseFile() {
        guard !busy, state != .running else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择本地 Stash / Clash YAML 配置；原文件不会被修改。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1024 * 1024 else { throw ProxyFailure.message("配置不能超过 2 MiB。") }
            let data = try Data(contentsOf: url)
            let result = try ProxyConfigCompiler.inspect(data)
            importData = data; importName = url.lastPathComponent; confirmRepairs = false; importPreview = result
        } catch { self.error = error.localizedDescription }
    }
    func confirmImport() {
        guard let importData, let preview = importPreview, !preview.hasErrors else { return }
        if preview.issues.contains(where: { $0.severity == .repair }), !confirmRepairs { error = "请确认兼容修复。"; return }
        do {
            let profile = try store.importProfile(data: importData, name: importName)
            profiles = try store.profiles(); selectedID = profile.id
            preferences.repairReferences = confirmRepairs
            preferences.allowLAN = preview.source["allow-lan"] as? Bool ?? false
            if let port = preview.source["mixed-port"] as? Int, (1024...65535).contains(port) { preferences.mixedPort = port }
            if let mode = preview.source["mode"] as? String, ["rule", "global", "direct"].contains(mode) { preferences.mode = mode }
            preferences.selections = [:]
            try store.save(preferences); try saveSelection(); try loadInspection()
            self.importData = nil; importPreview = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func saveSelection() throws {
        if let selectedID { try ProxyFiles.write(JSONEncoder().encode(selectedID), to: store.root.appendingPathComponent("selected-profile.json")) }
    }
    func selectProfile(_ id: UUID) {
        guard !busy, id != selectedID else { return }
        guard !editorDirty else { error = "请先保存或放弃未保存的草稿。"; return }
        run { try await self.applyTransaction(id: id, draft: self.store.committed(id), note: "切换配置", commit: false) }
    }
    func savePreferences(_ updated: ProxyPreferences) {
        guard !busy, state != .running else { return }
        do { try store.save(updated); preferences = updated; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func setAutoStart(_ enabled: Bool) {
        do { var updated = preferences; updated.autoStart = enabled; try store.save(updated); preferences = updated }
        catch { self.error = error.localizedDescription }
    }
    static func checkPorts(_ preferences: ProxyPreferences) throws {
        for (port, kind) in [(preferences.mixedPort, SOCK_STREAM), (preferences.controllerPort, SOCK_STREAM), (preferences.dnsPort, SOCK_STREAM), (preferences.dnsPort, SOCK_DGRAM)] {
            let fd = socket(AF_INET, kind, 0)
            guard fd >= 0 else { throw ProxyFailure.message("无法检查本地端口。") }
            if kind == SOCK_STREAM { var reuse: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            let available = result == 0 && (kind != SOCK_STREAM || listen(fd, 1) == 0)
            Darwin.close(fd)
            guard available else { throw ProxyFailure.message("端口 \(port) 已被占用，请停止其他代理或修改端口。") }
        }
    }
    func start() {
        guard canStart, featureEnabled else { return }
        run { await self.startWithRecovery() }
    }
    private func startWithRecovery() async {
        do { try await startCore() }
        catch {
            let message = error is CancellationError ? "启动已取消。" : error.localizedDescription
            do { try await stopCore() }
            catch { state = .failed; self.error = "\(message)\n停止或网络恢复未完成：\(error.localizedDescription)"; return }
            api = nil; self.error = message
        }
    }
    private func startCore(workOverride: URL? = nil) async throws {
        guard let id = selectedID, let inspection else { throw ProxyFailure.message("请先导入配置。") }
        state = .starting; statusDetail = "正在校验核心与配置…"
        try preferences.validate()
        try ProxyFiles.directory(store.root)
        try guardian.launch(executable: guardianExecutable, root: store.root)
        _ = try await guardian.send(.init(command: "recover"))
        try ProxyCore.verify(executable: coreExecutableURL, manifest: coreManifestURL)
        try Self.checkPorts(preferences)
        try Task.checkCancellation()
        let work = try workOverride ?? store.savedRuntime(id)
        try ProxyFiles.directory(work); try ProxyFiles.directory(work.appendingPathComponent("ruleset"))
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw ProxyFailure.message("无法生成控制密钥。") }
        let secret = random.map { String(format: "%02x", $0) }.joined()
        let config = work.appendingPathComponent("runtime.yaml")
        try ProxyFiles.write(ProxyConfigCompiler.compile(inspection, preferences: preferences, secret: secret), to: config)
        statusDetail = "正在准备远程规则和 GEO 缓存…"
        try await ProxyResources.prepare(inspection, work: work)
        statusDetail = "正在校验核心配置…"
        try await ProxyCore.validate(executable: coreExecutableURL, work: work, config: config)
        try Task.checkCancellation()
        var tunnelInterface: String?
        if preferences.tunnelSettings.enabled {
            statusDetail = "核对 VPN 路由并准备 TUN 网卡…"
            let plan = try await ProxyTunnelPreflight.plan(inspection: inspection, settings: preferences.tunnelSettings)
            let (handle, reply) = try await tunnelClient.prepare(plan)
            tunnelSession = true
            defer { try? handle.close() }
            guard let name = reply.interface, let address = reply.address4 else { throw ProxyFailure.message("助手未返回有效的 TUN 网卡。") }
            let runtime = ProxyTunnelRuntime(interface: name, address4: address, address6: reply.address6)
            try ProxyFiles.write(ProxyConfigCompiler.compile(inspection, preferences: preferences, secret: secret, tunnel: runtime), to: config)
            try guardian.sendTunnel(handle, root: store.root)
            tunnelInterface = name
        }
        try Task.checkCancellation()
        _ = try await guardian.send(.init(command: "start", corePath: coreExecutableURL.path, workPath: work.path, configPath: config.path, tunInterface: tunnelInterface))
        let client = ProxyAPI(port: preferences.controllerPort, secret: secret)
        api = client
        statusDetail = "等待核心和必要规则集就绪…"
        try await client.ready(requiredProviders: inspection.requiredProviders, deadline: Date().addingTimeInterval(90))
        try Task.checkCancellation()
        var liveGroups = try await client.groups()
        for (name, member) in preferences.selections where liveGroups.contains(where: { $0.name == name && $0.members.contains(member) }) {
            _ = try await client.request(["proxies", name], method: "PUT", body: ["name": member])
        }
        liveGroups = try await client.groups()
        if let tunnelInterface {
            let configuration = try await client.request(["configs"])
            guard let tun = configuration["tun"] as? [String: Any], tun["enable"] as? Bool == true,
                  tun["device"] as? String == tunnelInterface else {
                throw ProxyFailure.message("核心未成功启动指定 TUN 网卡，未添加接管路由。")
            }
            try await tunnelClient.activate()
        }
        preferSystemHelper = systemClient.available
        if preferences.systemProxy {
            statusDetail = "正在设置系统代理…"
            try await applySystemProxy(true)
        }
        try Task.checkCancellation()
        groups = ordered(liveGroups); state = .running; error = nil
        statusDetail = "Mihomo \(ProxyCore.version) · 配置和必要规则集已就绪"
        // Only the successfully started preferences become the next launch defaults.
        try store.save(preferences)
        activeWork = work
        if workOverride == nil { try store.markHealthy(id) }
        telemetry.start(api: client, source: inspection.source, proxyPort: preferences.mixedPort)
        monitor()
    }
    private func ordered(_ live: [ProxyGroup]) -> [ProxyGroup] {
        let order = inspection?.groups.map(\.name) ?? []
        return live.sorted { (order.firstIndex(of: $0.name) ?? Int.max, $0.name) < (order.firstIndex(of: $1.name) ?? Int.max, $1.name) }
    }
    func stop() {
        statusDetail = "正在停止当前操作并恢复网络…"
        Task { _ = await stopAndWait() }
    }
    private func stopCore() async throws {
        delayTask?.cancel(); delayTask = nil; delayGeneration = UUID()
        testingNodes.removeAll(); delays.removeAll(); delayDates.removeAll()
        monitoring?.cancel(); monitoring = nil
        telemetry.stop()
        state = .stopping
        do {
            if systemHelperSession { try await systemClient.stop(); systemHelperSession = false }
            if tunnelSession { try await tunnelClient.stop(); tunnelSession = false; tunnelEffective = false }
            if !guardian.isRunning, FileManager.default.fileExists(atPath: store.root.appendingPathComponent("system-proxy.plist").path) { try guardian.launch(executable: guardianExecutable, root: store.root) }
            if guardian.isRunning { _ = try await guardian.send(.init(command: "stop")) }
            api = nil; systemProxyEffective = false; state = .stopped; statusDetail = "系统代理已恢复。"
            groups = inspection?.groups ?? []
        } catch { state = .failed; throw error }
    }
    func stopAndWait() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        let task = Task { @MainActor in
            self.operation?.cancel()
            await self.operation?.value
            self.busy = true
            defer { self.busy = false }
            do { try await self.stopCore(); await self.telemetry.finishArchive(); return true }
            catch { self.error = error.localizedDescription; return false }
        }
        shutdownTask = task
        let result = await task.value
        shutdownTask = nil
        return result
    }
    private func applySystemProxy(_ enabled: Bool) async throws {
        if preferSystemHelper || systemHelperSession {
            // Record before awaiting: a failed XPC response may follow a successful OS write.
            systemHelperSession = true
            if enabled { try await systemClient.enable(port: preferences.mixedPort) }
            else { try await systemClient.stop(); systemHelperSession = false; systemProxyEffective = false }
        } else {
            _ = try await guardian.send(.init(command: "system", mixedPort: preferences.mixedPort, systemProxy: enabled))
        }
    }
    func setSystemProxy(_ enabled: Bool) {
        if state != .running { var updated = preferences; updated.systemProxy = enabled; savePreferences(updated); return }
        run {
            try await self.applySystemProxy(enabled)
            self.preferences.systemProxy = enabled
            try self.store.save(self.preferences)
        }
    }
    func setMode(_ mode: String) {
        guard ["rule", "global", "direct"].contains(mode) else { return }
        if state != .running { var updated = preferences; updated.mode = mode; savePreferences(updated); return }
        run {
            guard let api = self.api else { return }
            _ = try await api.request(["configs"], method: "PATCH", body: ["mode": mode])
            let actual = try await api.request(["configs"])
            guard actual["mode"] as? String == mode else { throw ProxyFailure.message("出站模式回读不一致。") }
            self.preferences.mode = mode; try self.store.save(self.preferences)
        }
    }
    func setLAN(_ enabled: Bool) {
        if state != .running { var updated = preferences; updated.allowLAN = enabled; savePreferences(updated); return }
        run {
            let old = self.preferences
            try await self.stopCore()
            self.preferences.allowLAN = enabled
            do { try await self.startCore() }
            catch {
                let message = error.localizedDescription
                try await self.stopCore(); self.preferences = old
                do { try await self.startCore() } catch { try? await self.stopCore(); self.state = .failed }
                throw ProxyFailure.message("LAN 修改失败，已尝试恢复原配置：\(message)")
            }
        }
    }
    func choose(group: String, member: String) {
        guard state == .running else { return }
        run {
            guard let api = self.api else { return }
            _ = try await api.request(["proxies", group], method: "PUT", body: ["name": member])
            let actual = try await api.groups()
            guard actual.contains(where: { $0.name == group && $0.selected == member }) else { throw ProxyFailure.message("节点切换回读失败。") }
            self.groups = self.ordered(actual); self.preferences.selections[group] = member
            try self.store.save(self.preferences)
        }
    }
    func test(_ names: [String]) {
        guard state == .running, let api, testingNodes.isEmpty else { return }
        let targets = Array(Set(names)).sorted().prefix(50).filter { !["REJECT", "REJECT-DROP"].contains($0) }
        let generation = UUID(); delayGeneration = generation
        testingNodes = Set(targets)
        delayTask = Task { [weak self] in
            for name in targets {
                guard !Task.isCancelled else { return }
                let result = try? await api.request(["proxies", name, "delay"], query: [.init(name: "timeout", value: "5000"), .init(name: "url", value: "https://www.gstatic.com/generate_204")])
                guard let self, !Task.isCancelled, self.delayGeneration == generation, self.state == .running else { return }
                let delay = result?["delay"] as? Int ?? -1
                self.delays[name] = delay > 0 ? delay : -1
                self.delayDates[name] = Date()
                self.testingNodes.remove(name)
            }
        }
    }
    private func monitor() {
        monitoring?.cancel()
        monitoring = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, self.state == .running, let api = self.api else { return }
                if self.busy { continue }
                do { _ = try await api.request(["version"]); failures = 0; self.telemetry.flush() }
                catch { failures += 1 }
                if failures >= 3 {
                    self.run {
                        try await self.stopCore()
                        self.error = "核心连续无响应，已停止代理并恢复网络。"
                    }
                    return
                }
            }
        }
    }
    func copyShell(host: String = "127.0.0.1") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProxyConfigCompiler.shellCommands(host: host, port: preferences.mixedPort), forType: .string)
    }
    func copyUnset() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("unset http_proxy https_proxy all_proxy", forType: .string)
    }
}

extension ProxyService {
    private func loadEditor() throws {
        guard let id = selectedID else { editorYAML = ""; editorOverrides = ""; revisionHistory = []; return }
        let draft = try store.draft(id)
        editorYAML = draft.yaml; editorOverrides = draft.overrides; editorSaved = draft
        revisionHistory = try store.revisions(id).revisions.reversed()
        draftReport = []; draftDiff = ""
    }
    func saveDraft() {
        guard let id = selectedID, !busy else { return }
        do {
            let draft = ProxyDraft(yaml: editorYAML, overrides: editorOverrides)
            try store.saveDraft(draft, for: id); editorSaved = draft; statusDetail = "草稿已保存，运行配置未改变。"; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func discardDraft() {
        guard let id = selectedID, !busy else { return }
        do { let draft = try store.committed(id); try store.saveDraft(draft, for: id); try loadEditor() }
        catch { self.error = error.localizedDescription }
    }
    func inspectDraft() {
        guard let id = selectedID else { return }
        do {
            let draft = ProxyDraft(yaml: editorYAML, overrides: editorOverrides)
            let effective = try draft.effective()
            draftReport = try ProxyConfigCompiler.inspect(effective).issues
            let old = try store.committed(id).effective()
            draftDiff = ProxyDiff.text(before: String(decoding: old, as: UTF8.self), after: String(decoding: effective, as: UTF8.self))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func applyDraft() {
        guard let id = selectedID else { return }
        let draft = ProxyDraft(yaml: editorYAML, overrides: editorOverrides)
        run { try await self.applyTransaction(id: id, draft: draft, note: "应用草稿", commit: true) }
    }
    func reloadProfile() {
        guard let id = selectedID else { return }
        run { try await self.applyTransaction(id: id, draft: self.store.committed(id), note: "重新加载", commit: false) }
    }
    func rollback(_ revision: ProxyRevision) {
        guard let id = selectedID, !editorDirty else { error = "请先保存或放弃当前未保存的草稿。"; return }
        run { try await self.applyTransaction(id: id, draft: revision.draft, note: "回退至 \(revision.createdAt.formatted())", commit: true) }
    }
    private func applyTransaction(id: UUID, draft: ProxyDraft, note: String, commit: Bool) async throws {
        let candidate = try ProxyConfigCompiler.inspect(draft.effective())
        // The profile is the source of truth for its mixed port. Keep the
        // runtime preferences in sync before compiling, otherwise compile()
        // would silently replace a YAML port (for example 7891) with the
        // previous UI default (7890).
        if let port = candidate.source["mixed-port"] as? Int,
           (1024...65535).contains(port) {
            preferences.mixedPort = port
        }
        var committedCandidate = false
        let revision = ProxyRevision(note: note, draft: draft)
        let work = store.runtime(id).appendingPathComponent("candidate-\(revision.id.uuidString)")
        try ProxyFiles.directory(work)
        defer { if !committedCandidate && activeWork != work { try? FileManager.default.removeItem(at: work) } }
        if let activeWork { try ProxyResources.copyCaches(from: activeWork, to: work) }
        else { try ProxyResources.copyCaches(from: store.savedRuntime(id), to: work) }
        let config = work.appendingPathComponent("runtime.yaml")
        try ProxyFiles.write(ProxyConfigCompiler.compile(candidate, preferences: preferences, secret: UUID().uuidString), to: config)
        statusDetail = "校验候选配置；原配置仍保持运行…"
        try await ProxyResources.prepare(candidate, work: work)
        try await ProxyCore.validate(executable: coreExecutableURL, work: work, config: config)
        try Task.checkCancellation()
        let oldID = selectedID, oldInspection = inspection, oldPreferences = preferences, oldWork = activeWork
        let wasRunning = state == .running
        try store.beginApply(previous: oldID, target: id)
        do { if wasRunning { try await stopCore() } } catch { try? store.recoverApply(); throw error }
        selectedID = id; inspection = candidate
        do {
            if wasRunning { try await startCore(workOverride: work) }
            if commit { try store.commit(revision, for: id, healthy: wasRunning) }
            else if wasRunning { try store.markHealthy(id) }
            try saveSelection()
            try store.saveRuntime(work, for: id)
            try store.save(preferences)
            if commit { try? store.saveDraft(draft, for: id) }
            try loadEditor()
            try store.finishApply()
            committedCandidate = true
            try? store.pruneRuntime(id, keeping: work)
            if !wasRunning { groups = candidate.groups }
            statusDetail = wasRunning ? "候选配置已生效；失败回退保护已就绪。" : "配置已校验并保存；尚未启动代理。"
        } catch {
            let reason = error.localizedDescription
            try store.recoverApply()
            if wasRunning { try await stopCore() }
            selectedID = oldID; inspection = oldInspection; preferences = oldPreferences
            if Task.isCancelled { state = .stopped; throw CancellationError() }
            if wasRunning {
                do { try await startCore(workOverride: oldWork) }
                catch { state = .failed; throw ProxyFailure.message("应用失败，旧配置恢复也失败：\(reason)；\(error.localizedDescription)") }
            }
            throw ProxyFailure.message("候选配置未生效，已保留原配置：\(reason)")
        }
    }
    func renameProfile(_ name: String) {
        guard let id = selectedID, !busy else { return }
        do { try store.rename(id, name: name); profiles = try store.profiles() } catch { self.error = error.localizedDescription }
    }
    func duplicateProfile() {
        guard let id = selectedID, !busy else { return }
        do { _ = try store.duplicate(id); profiles = try store.profiles() } catch { self.error = error.localizedDescription }
    }
    func deleteSelectedProfile() {
        guard let id = selectedID, !busy, state == .stopped else { return }
        do { try store.remove(id); profiles = try store.profiles(); selectedID = profiles.first?.id; try saveSelection(); try loadInspection() }
        catch { self.error = error.localizedDescription }
    }
    func exportProfile(original: Bool = false) {
        guard let id = selectedID else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = selectedProfile?.name ?? "profile.yaml"
        panel.message = "导出的配置含节点凭据，请保存到可信位置。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = original ? try Data(contentsOf: store.original(id)) : try store.committed(id).effective(); try ProxyFiles.write(data, to: url) }
        catch { self.error = error.localizedDescription }
    }
    func originalText() -> String { guard let id = selectedID else { return "" }; return (try? String(contentsOf: store.original(id), encoding: .utf8)) ?? "" }
    func effectiveText() -> String {
        guard let inspection else { return "" }
        return (try? String(decoding: ProxyConfigCompiler.compile(inspection, preferences: preferences, secret: "<每次启动随机生成>"), as: UTF8.self)) ?? ""
    }
    func replaceRules(_ rules: [String]) throws {
        var root = try ProxyConfigCompiler.document(Data(editorYAML.utf8))
        root["rules"] = rules
        editorYAML = String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    var draftRules: [String] { (try? ProxyConfigCompiler.document(Data(editorYAML.utf8))["rules"] as? [String]) ?? [] }
    func refreshResources(update: String? = nil) {
        guard state == .running else { resourceStates = []; return }
        run {
            guard let api = self.api else { return }
            if let update {
                let names = update == "*" ? (self.inspection?.source["rule-providers"] as? [String: Any] ?? [:]).keys.sorted() : [update]
                for name in names { _ = try await api.request(["providers", "rules", name], method: "PUT") }
            }
            self.resourceStates = try await api.resources()
        }
    }
}

extension ProxyService {
    func refreshTunnelAccess() { tunnelAccess = tunnelClient.accessText }
    func authorizeTunnel() {
        do { try tunnelClient.authorize(); tunnelAccess = tunnelClient.accessText; error = nil }
        catch { self.error = error.localizedDescription; tunnelAccess = tunnelClient.accessText }
    }
    func removeTunnelHelper() {
        guard !busy, !tunnelSession, !systemHelperSession, state == .stopped else { error = "请先停止代理再移除网络助手。"; return }
        run { try await self.tunnelClient.unregister(); self.tunnelAccess = self.tunnelClient.accessText }
    }
    func setTunnel(_ enabled: Bool) {
        if state != .running { var next = preferences; next.tunnelSettings.enabled = enabled; savePreferences(next); return }
        run {
            let previous = self.preferences
            try await self.stopCore()
            self.preferences.tunnelSettings.enabled = enabled
            do { try await self.startCore() }
            catch {
                let reason = error.localizedDescription
                try await self.stopCore(); self.preferences = previous
                do { try await self.startCore() }
                catch { try? await self.stopCore(); self.state = .failed; throw ProxyFailure.message("增强模式切换失败且旧模式无法恢复：\(reason)；\(error.localizedDescription)") }
                throw ProxyFailure.message("增强模式切换失败，已恢复原模式：\(reason)")
            }
        }
    }
}

extension ProxyService {
    func previewTunnel() {
        guard let inspection else { return }
        run {
            let plan = try await ProxyTunnelPreflight.plan(inspection: inspection, settings: self.preferences.tunnelSettings)
            let snapshot = try await Task.detached { try ProxyNetworkSnapshot.read() }.value
            let routes = try plan.routes(snapshot: snapshot)
            self.tunnelPreview = "计划接管 \(routes.count) 条公网路由；保留本地网段、DNS、节点地址与当前 VPN 路由。\n显式排除：\n" + plan.exclusions.joined(separator: "\n") + "\n\n当前隧道路由：\n" + snapshot.routes.filter(\.isTunnel).map { "\($0.prefix) → \($0.interface)" }.joined(separator: "\n")
        }
    }
    func diagnoseCompany(server: String, domain: String, port: Int) {
        run { self.networkChecks = await ProxyCompanyDiagnostics.run(server: server, domain: domain, port: port) }
    }
    var companyDefaults: (server: String, domain: String) {
        let dns = inspection?.source["dns"] as? [String: Any] ?? [:]
        let policies = dns["nameserver-policy"] as? [String: Any] ?? [:]
        for key in policies.keys.sorted() where !key.contains("*") && !key.contains(":") {
            let text = policies[key] as? String ?? (policies[key] as? [String])?.first ?? ""
            if let server = URL(string: text.contains("://") ? text : "udp://" + text)?.host, (try? ProxyCIDR(server)) != nil { return (server, key) }
        }
        return ("", "")
    }
    func replaceSection(_ key: String, with value: Any) throws {
        var root = try ProxyConfigCompiler.document(Data(editorYAML.utf8))
        root[key] = value
        editorYAML = String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}


extension ProxyService {
    func diagnosticData() throws -> Data {
        let report: [String: Any] = [
            "schema": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
            "applicationVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "applicationBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            "buildCommit": Bundle.main.object(forInfoDictionaryKey: "VorssaintBuildCommit") as? String ?? "unavailable",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "coreVersion": ProxyCore.version, "architecture": ProxyCore.architecture,
            "state": stateText, "mode": preferences.mode,
            "systemProxyEffective": systemProxyEffective, "tunEffective": tunnelEffective,
            "tunValidation": "deferred", "allowLAN": preferences.allowLAN,
            "ports": ["mixed": preferences.mixedPort, "controller": preferences.controllerPort, "dns": preferences.dnsPort],
            "profileCount": profiles.count, "nodeCount": inspection?.nodeNames.count ?? 0,
            "groupCount": groups.count, "ruleCount": inspection?.ruleCount ?? 0,
            "connectionCount": telemetry.connectionCount, "coreMemoryBytes": telemetry.memory.map { $0 as Any } ?? NSNull(),
            "uploadBytes": telemetry.uploadTotal, "downloadBytes": telemetry.downloadTotal,
            "telemetryFresh": telemetry.sampleDate.map { Date().timeIntervalSince($0) < 5 } ?? false,
            "logEntryCount": telemetry.logs.count
        ]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }
}
