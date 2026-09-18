// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine
import ProxyTunnelBridge

struct ProxyConnection: Identifiable {
    let id: String
    let process: String
    let processKey: String
    let host: String
    let destination: String
    let network: String
    let rule: String
    let chains: String
    let started: String
    let upload: Double
    let download: Double
    var uploadRate: Double = 0
    var downloadRate: Double = 0
    static func parse(_ value: [String: Any]) -> ProxyConnection? {
        guard let id = value["id"] as? String, !id.isEmpty else { return nil }
        let metadata = value["metadata"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String { String((metadata[key] as? String ?? "").prefix(1024)) }
        let path = text("processPath"), name = text("process")
        let source = text("sourceIP")
        let fallback = source.isEmpty || ["127.0.0.1", "::1"].contains(source)
            ? "本机进程（未识别）" : "客户端 · " + source
        let process = name.isEmpty ? (path.isEmpty ? fallback : URL(fileURLWithPath: path).lastPathComponent) : name
        let port = metadata["destinationPort"].map { String(describing: $0) } ?? ""
        return .init(id: String(id.prefix(256)), process: process, processKey: path.isEmpty ? process : path,
                     host: text("host"), destination: text("destinationIP") + ":" + port,
                     network: text("network"), rule: String(([value["rule"] as? String, value["rulePayload"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")).prefix(512)),
                     chains: (value["chains"] as? [String] ?? []).prefix(20).joined(separator: " → "),
                     started: String((value["start"] as? String ?? "").prefix(80)),
                     upload: counter(value["upload"]), download: counter(value["download"]))
    }
    static func counter(_ value: Any?) -> Double { let n = (value as? NSNumber)?.doubleValue ?? 0; return n.isFinite ? max(0, n) : 0 }
}
struct ProxyActiveClient: Identifiable {
    let id: String
    let name: String
    var count = 0
    var uploadRate: Double = 0
    var downloadRate: Double = 0
}
struct ProxyTrafficPoint: Identifiable {
    let id = UUID()
    let date: Date
    let upload: Double
    let download: Double
}
struct ProxyTrafficSampler {
    private var previous: [String: ProxyConnection] = [:]
    private var time: TimeInterval?
    private var totals: (Double, Double)?
    mutating func reset() { self = .init() }
    mutating func sample(_ root: [String: Any], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (connections: [ProxyConnection], clients: [ProxyActiveClient], up: Double, down: Double, count: Int) {
        let rows = root["connections"] as? [[String: Any]] ?? []
        let elapsed = time.map { now - $0 } ?? 0
        let valid = elapsed > 0 && elapsed < 15
        let up = ProxyConnection.counter(root["uploadTotal"]), down = ProxyConnection.counter(root["downloadTotal"])
        var seen = Set<String>()
        let connections = rows.prefix(5000).compactMap(ProxyConnection.parse).filter { seen.insert($0.id).inserted }.map { row in
            var row = row
            if valid, let old = previous[row.id] {
                row.uploadRate = max(0, row.upload - old.upload) / elapsed
                row.downloadRate = max(0, row.download - old.download) / elapsed
            }
            return row
        }
        var clients: [String: ProxyActiveClient] = [:]
        for row in connections {
            var client = clients[row.processKey] ?? .init(id: row.processKey, name: row.process)
            client.count += 1; client.uploadRate += row.uploadRate; client.downloadRate += row.downloadRate
            clients[row.processKey] = client
        }
        let rates = valid && totals != nil ? (max(0, up - totals!.0) / elapsed, max(0, down - totals!.1) / elapsed) : (0, 0)
        previous = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) }); time = now; totals = (up, down)
        return (connections, clients.values.sorted { ($0.uploadRate + $0.downloadRate, $0.id) > ($1.uploadRate + $1.downloadRate, $1.id) }, rates.0, rates.1, rows.count)
    }
}
struct ProxyLogEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    let level: String
    let message: String
}
struct ProxyLogRedactor {
    let secrets: [String]
    init(source: [String: Any], controllerSecret: String) {
        var values = [controllerSecret]
        func walk(_ object: Any) {
            if let map = object as? [String: Any] {
                for (key, value) in map {
                    if ["password", "uuid", "secret", "private-key", "short-id", "token", "authorization"].contains(key.lowercased()), let text = value as? String, !text.isEmpty { values.append(text) }
                    else { walk(value) }
                }
            } else if let array = object as? [Any] { array.forEach(walk) }
        }
        walk(source); secrets = Array(Set(values.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
    }
    func redact(_ value: String) -> String {
        var text = value
        for secret in secrets { text = text.replacingOccurrences(of: secret, with: "[凭据已隐藏]") }
        for pattern in [#"(?i)(bearer\s+)[^\s]+"#, #"(?i)(password|token|secret|uuid|authorization)[=:]\s*[^\s,;]+"#, #"\b[a-zA-Z][a-zA-Z0-9+.-]{0,20}://[^\s]+"#] {
            text = text.replacingOccurrences(of: pattern, with: "[敏感字段已隐藏]", options: .regularExpression)
        }
        return String(text.prefix(8192))
    }
}
actor ProxyLogArchive {
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    func append(_ entries: [ProxyLogEntry]) throws {
        guard !entries.isEmpty else { return }
        try ProxyFiles.directory(directory)
        let current = directory.appendingPathComponent("events.jsonl"), old = directory.appendingPathComponent("events.previous.jsonl")
        var data = (try? Data(contentsOf: current)) ?? Data()
        guard data.count <= 512 * 1024 else { throw ProxyFailure.message("日志缓存超过大小限制。") }
        for entry in entries {
            var line = try JSONEncoder().encode(entry); line.append(10)
            guard line.count <= 512 * 1024 else { continue }
            if data.count + line.count > 512 * 1024 {
                try ProxyFiles.write(data, to: old); data = Data()
            }
            data.append(line)
        }
        try ProxyFiles.write(data, to: current)
    }

    func load() throws -> [ProxyLogEntry] {
        var entries: [ProxyLogEntry] = []
        for name in ["events.previous.jsonl", "events.jsonl"] {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1024 else { throw ProxyFailure.message("日志缓存超过大小限制。") }
            let data = try Data(contentsOf: file)
            entries += data.split(separator: 10).compactMap { try? JSONDecoder().decode(ProxyLogEntry.self, from: Data($0)) }
        }
        return Array(entries.suffix(1000))
    }
    func clear() throws {
        for name in ["events.jsonl", "events.previous.jsonl"] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}

@MainActor final class ProxyTelemetry: ObservableObject {
    @Published private(set) var connections: [ProxyConnection] = []
    @Published private(set) var clients: [ProxyActiveClient] = []
    @Published private(set) var history: [ProxyTrafficPoint] = []
    @Published private(set) var logs: [ProxyLogEntry] = []
    @Published private(set) var uploadRate = 0.0
    @Published private(set) var downloadRate = 0.0
    @Published private(set) var uploadTotal = 0.0
    @Published private(set) var downloadTotal = 0.0
    @Published private(set) var memory: Double?
    @Published private(set) var connectionCount = 0
    @Published private(set) var sampleDate: Date?
    @Published private(set) var issue: String?
    @Published private(set) var logIssue: String?
    @Published private(set) var droppedLogCount = 0
    @Published var logLevel = "warning" { didSet { if oldValue != logLevel { restartLogs() } } }
    @Published var logsPaused = false { didSet { restartLogs() } }
    @Published var processFilter: String?
    @Published var selectedPage = 0
    private var consumers = Set<String>()
    private var proxyPort = 0
    private var processPaths: [String: String] = [:]
    private var api: ProxyAPI?
    private var sampling: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var memorySocket: URLSessionWebSocketTask?
    private var logging: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var sampler = ProxyTrafficSampler()
    private var redactor = ProxyLogRedactor(source: [:], controllerSecret: "")
    private let archive: ProxyLogArchive
    private var pending: [ProxyLogEntry] = []
    private var archiveWriter: Task<Void, Never>?
    private var archiveResetRequested = false
    private var archiveGeneration = UUID()
    init(root: URL) {
        archive = ProxyLogArchive(directory: root.appendingPathComponent("Logs"))
        let token = archiveGeneration
        Task { [weak self, archive] in
            do {
                let saved = try await archive.load()
                guard let self, self.archiveGeneration == token else { return }
                let existing = Set(self.logs.map(\.id))
                self.logs = Array((saved.filter { !existing.contains($0.id) } + self.logs).suffix(1000))
            } catch { self?.logIssue = "历史日志读取失败，新日志仍会继续采集。" }
        }
    }
    func setVisible(_ id: String, _ visible: Bool) {
        if visible { consumers.insert(id) } else { consumers.remove(id) }
        refreshSampling()
    }
    func start(api: ProxyAPI, source: [String: Any], proxyPort: Int = 0) {
        stop(); self.api = api; self.proxyPort = proxyPort; redactor = .init(source: source, controllerSecret: api.secret)
        addLog(level: "info", message: "核心已就绪。")
        refreshSampling(); restartLogs()
    }
    func stop() {
        stopMemory(); processPaths.removeAll()
        generation = UUID(); sampling?.cancel(); sampling = nil; logging?.cancel(); logging = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; api = nil; sampler.reset()
        connections = []; clients = []; connectionCount = 0; uploadRate = 0; downloadRate = 0; memory = nil; sampleDate = nil
        history = []; uploadTotal = 0; downloadTotal = 0; issue = nil
        flush()
    }
    private func refreshSampling() {
        guard !consumers.isEmpty, let api else { sampling?.cancel(); sampling = nil; stopMemory(); sampler.reset(); sampleDate = nil; uploadRate = 0; downloadRate = 0; return }
        if memoryTask == nil { startMemory(api) }
        guard sampling == nil else { return }
        let token = generation
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let snapshot = try await api.request(["connections"])
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    let enriched = await self.resolveProcesses(snapshot)
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.ingest(enriched); self.issue = nil
                } catch {
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.issue = "连接数据暂不可用，正在重试。"; self.sampleDate = nil; self.sampler.reset(); self.uploadRate = 0; self.downloadRate = 0
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    private func resolveProcesses(_ snapshot: [String: Any]) async -> [String: Any] {
        guard proxyPort > 0, var rows = snapshot["connections"] as? [[String: Any]] else { return snapshot }
        func needsPath(_ row: [String: Any]) -> Bool {
            let m = row["metadata"] as? [String: Any] ?? [:]
            return (m["process"] as? String ?? "").isEmpty && (m["processPath"] as? String ?? "").isEmpty
                && ["127.0.0.1", "::1"].contains(m["sourceIP"] as? String ?? "")
                && (m["network"] as? String ?? "").lowercased() == "tcp"
        }
        let token = generation
        let port = UInt16(clamping: proxyPort)
        let missing = rows.contains { needsPath($0) && processPaths[$0["id"] as? String ?? ""] == nil }
        let paths: [String: String] = missing ? await Task.detached(priority: .utility) {
            var records = [VPTLocalProcess](repeating: .init(), count: 2048)
            let count = VPTLocalProcesses(port, &records, Int32(records.count))
            var paths: [String: String] = [:]
            for var record in records.prefix(Int(count)) {
                let path = withUnsafeBytes(of: &record.path) { bytes in String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                paths["\(record.ipv6):\(record.source_port)"] = path
            }
            return paths
        }.value : [:]
        guard generation == token else { return snapshot }
        let liveIDs = Set(rows.compactMap { $0["id"] as? String })
        processPaths = processPaths.filter { liveIDs.contains($0.key) }
        for index in rows.indices where needsPath(rows[index]) {
            guard let id = rows[index]["id"] as? String, var m = rows[index]["metadata"] as? [String: Any] else { continue }
            let sourcePort = (m["sourcePort"] as? Int) ?? Int(m["sourcePort"] as? String ?? "") ?? 0
            if let path = processPaths[id] ?? paths["\(m["sourceIP"] as? String == "::1" ? 1 : 0):\(sourcePort)"] {
                m["processPath"] = path; processPaths[id] = path; rows[index]["metadata"] = m
            }
        }
        var result = snapshot; result["connections"] = rows; return result
    }
    func ingest(_ root: [String: Any]) {
        let sample = sampler.sample(root)
        connections = sample.connections; clients = sample.clients; connectionCount = sample.count
        uploadRate = sample.up; downloadRate = sample.down; sampleDate = Date()
        uploadTotal = ProxyConnection.counter(root["uploadTotal"]); downloadTotal = ProxyConnection.counter(root["downloadTotal"])
        history.append(.init(date: Date(), upload: sample.up, download: sample.down)); if history.count > 60 { history.removeFirst(history.count - 60) }
    }
    func ingestMemory(_ root: [String: Any]) {
        let value = ProxyConnection.counter(root["inuse"])
        memory = value > 0 ? value : nil // Upstream intentionally emits zero for its first sample.
    }
    private func stopMemory() {
        memoryTask?.cancel(); memoryTask = nil; memorySocket?.cancel(with: .goingAway, reason: nil); memorySocket = nil; memory = nil
    }
    private func startMemory(_ api: ProxyAPI) {
        let token = generation
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                let ws = api.memorySocket(); self.memorySocket = ws; ws.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        guard !Task.isCancelled, self.generation == token else { return }
                        let data: Data
                        switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] { self.ingestMemory(root) }
                    }
                } catch {
                    ws.cancel(with: .goingAway, reason: nil)
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.memory = nil
                }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }
    private func restartLogs() {
        logging?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil; logging = nil
        guard let api, !logsPaused else { flush(); return }
        let token = generation, level = ["debug", "info", "warning", "error", "silent"].contains(logLevel) ? logLevel : "warning"
        logging = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                let ws = api.logSocket(level: level)
                do {
                    _ = try await api.request(["configs"], method: "PATCH", body: ["log-level": level])
                    guard !Task.isCancelled, self.generation == token else { ws.cancel(with: .goingAway, reason: nil); return }
                    self.socket = ws; ws.resume()
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        guard !Task.isCancelled, self.generation == token else { return }
                        let data: Data
                        switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                        guard data.count <= 65536, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = value["payload"] as? String else { continue }
                        self.logIssue = nil; self.addLog(level: value["type"] as? String ?? "info", message: payload)
                    }
                } catch {
                    ws.cancel(with: .goingAway, reason: nil)
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.logIssue = "日志流暂不可用，3 秒后重试。"
                }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }
    func addLog(level: String, message: String) {
        let entry = ProxyLogEntry(level: level, message: redactor.redact(message))
        logs.append(entry); if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
        pending.append(entry); if pending.count > 1000 { droppedLogCount += pending.count - 1000; pending.removeFirst(pending.count - 1000) }
        if pending.count >= 50 { flush() }
    }
    func flush() {
        guard archiveWriter == nil, !pending.isEmpty || archiveResetRequested else { return }
        archiveWriter = Task {
            defer { archiveWriter = nil }
            while !pending.isEmpty || archiveResetRequested {
                do {
                    if archiveResetRequested { archiveResetRequested = false; try await archive.clear() }
                    let batch = Array(pending.prefix(50)); pending.removeFirst(batch.count)
                    try await archive.append(batch)
                } catch { pending = []; archiveResetRequested = false; logIssue = "日志缓存写入失败；内存日志仍可查看。"; return }
            }
        }
    }
    func clearLogs() {
        archiveGeneration = UUID(); logs = []; pending = []; droppedLogCount = 0; archiveResetRequested = true; flush()
    }
    func finishArchive() async { flush(); await archiveWriter?.value }
    func closeConnection(_ id: String) async throws {
        guard let api else { return }
        _ = try await api.request(["connections", id], method: "DELETE")
    }
    func closeAll() async throws {
        guard let api else { return }
        _ = try await api.request(["connections"], method: "DELETE")
    }
    static func bytes(_ value: Double) -> String { value <= 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(min(max(0, value), Double(Int64.max / 2))), countStyle: .binary) }
}
