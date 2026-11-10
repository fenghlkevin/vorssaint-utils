// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import Darwin

/// A single persistent nettop stream, independent of panel visibility.
final class AppTrafficService: ObservableObject {
    static let shared = AppTrafficService()
    @Published private(set) var ledger: AppTrafficLedger
    @Published private(set) var rates: [String: (down: Double, up: Double)] = [:]
    @Published private(set) var status = "starting"
    @Published private(set) var saveFailed = false
    private var process: Process?
    private var output: FileHandle?
    private var lifeline: FileHandle?
    private let streamQueue = DispatchQueue(label: "com.vorssaint.app-traffic-stream", qos: .utility)
    private var generation = 0
    private var stopped = true
    private var lastSample = Date()
    private var lastSave = Date.distantPast
    private var appNames: [String: String] = [:]
    private var watchdog: Timer?
    private let fileURL: URL

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Vorssaint", isDirectory: true)
        fileURL = folder.appendingPathComponent("app-traffic.json")
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        let bootDate = result == 0 ? Date(timeIntervalSince1970: Double(boot.tv_sec))
            : Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        ledger = AppTrafficLedger.restore(try? Data(contentsOf: fileURL),
                                         bootID: Int64(bootDate.timeIntervalSince1970.rounded()),
                                         bootDate: bootDate, now: Date())
        if ledger.includesLoopbackSince == nil { ledger.includesLoopbackSince = Date() }
    }

    func start() {
        guard stopped else { return }
        stopped = false
        launch()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastSample) > 20 {
                self.rates = [:]
                self.ledger.interrupted = true
                self.status = "waiting"
                if Date().timeIntervalSince(self.lastSample) > 30, self.process?.isRunning == true { self.process?.terminate() }
            }
        }
    }

    func stop() {
        stopped = true
        generation += 1
        watchdog?.invalidate()
        watchdog = nil
        lifelineClose()
        if process?.isRunning == true { process?.terminate() }
        output?.readabilityHandler = nil
        try? output?.close()
        output = nil
        process = nil
        save()
    }

    private func launch() {
        guard !stopped else { return }
        generation += 1
        let token = generation
        let task = Process()
        guard let executable = Bundle.main.executableURL else { retry(token: token); return }
        let pipe = Pipe()
        let parentPipe = Pipe()
        let reader = pipe.fileHandleForReading
        task.executableURL = executable
        task.arguments = ["--app-traffic-worker", String(getpid())]
        task.standardInput = parentPipe.fileHandleForReading
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        lifeline = parentPipe.fileHandleForWriting
        // Other subprocesses must not keep our parent lifeline alive.
        _ = fcntl(parentPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        output = reader
        let stream = TrafficStreamBuffer()
        reader.readabilityHandler = { [weak self] handle in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { handle.readabilityHandler = nil; return }
            let chunk = Data(buffer.prefix(count))
            self?.streamQueue.async { [weak self] in
                for samples in stream.consume(chunk) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token, !self.stopped else { return }
                        self.consume(samples)
                    }
                }
            }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.retry(token: token) }
        }
        process = task
        lastSample = Date()
        status = "starting"
        do {
            try task.run()
            try? pipe.fileHandleForWriting.close()
            try? parentPipe.fileHandleForReading.close()
        } catch { retry(token: token) }
    }

    private func lifelineClose() {
        try? lifeline?.close()
        lifeline = nil
    }

    private func retry(token: Int) {
        guard generation == token, !stopped else { return }
        generation += 1
        let retryGeneration = generation
        lifelineClose()
        if process?.isRunning == true { process?.terminate() }
        output?.readabilityHandler = nil
        try? output?.close()
        output = nil
        process = nil
        rates = [:]
        status = "failed"
        ledger.interrupted = true
        save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.generation == retryGeneration, !self.stopped else { return }
            self.launch()
        }
    }

    private func consume(_ samples: [NetworkProcessSample]) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSample)
        let validRate = status == "recording" && elapsed > 0 && elapsed < 10
        var current: [String: (down: Double, up: Double)] = [:]
        for sample in samples {
            let owner = ResponsibleProcess.regularAppOwner(of: sample.pid)
                ?? NSRunningApplication(processIdentifier: ResponsibleProcess.owner(of: sample.pid))
            let path = owner?.bundleURL?.path
            var name = owner?.localizedName ?? sample.name
            if let path {
                if let cached = appNames[path] { name = cached }
                else {
                    // This distribution embeds Codex in ChatGPT and shares its
                    // networking helpers. Do not claim it is Codex-only traffic.
                    if URL(fileURLWithPath: path).lastPathComponent == "ChatGPT.app",
                       FileManager.default.fileExists(atPath: path + "/Contents/Resources/codex-cli") {
                        name = "ChatGPT / Codex"
                    }
                    appNames[path] = name
                }
            }
            // Use a stable application path; unowned daemons stay separate by process name.
            let id = path.map { "app:" + $0 } ?? "process:" + sample.name
            ledger.add(id: id, name: name, appPath: path, child: sample.name,
                       down: sample.bytesIn, up: sample.bytesOut, now: now)
            if validRate {
                var rate = current[id] ?? (0, 0)
                rate.down += sample.bytesIn / elapsed
                rate.up += sample.bytesOut / elapsed
                current[id] = rate
            }
        }
        rates = current
        lastSample = now
        status = "recording"
        if now.timeIntervalSince(lastSave) >= 15 { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: fileURL, options: .atomic)
            lastSave = Date()
            saveFailed = false
        } catch { saveFailed = true }
    }
}

/// Confined to the stream serial queue; bytes can split at any line boundary.
private final class TrafficStreamBuffer: @unchecked Sendable {
    private var pending = Data()
    private var parser = NetworkProcessDeltaStreamParser()
    func consume(_ chunk: Data) -> [[NetworkProcessSample]] {
        pending.append(chunk)
        var sections: [[NetworkProcessSample]] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            if let section = parser.consumeCSVLine(line) { sections.append(section) }
        }
        if pending.count > 1024 * 1024 { pending.removeAll(); parser.reset() }
        return sections
    }
}
