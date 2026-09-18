// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import ProxyTunnelBridge

@MainActor
final class ProxyGuardianClient {
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<ProxyGuardianEvent, Error>] = [:]
    var onEvent: ((ProxyGuardianEvent) -> Void)?
    var isRunning: Bool { process?.isRunning == true }
    func launch(executable: URL, root: URL) throws {
        if isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ProxyFailure.message("构建缺少 ProxyGuardian 监管程序。") }
        try ProxyFiles.directory(root)
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = [root.path]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.process === ended else { return }
                self.input = nil
                let callbacks = self.pending.values; self.pending.removeAll()
                callbacks.forEach { $0.resume(throwing: ProxyFailure.message("核心监管进程已退出；请检查代理恢复状态。")) }
                self.onEvent?(.init(identifier: "guardian-exit", success: false, message: "监管进程已退出。"))
            }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                buffer.append(data)
                if buffer.count > 65536 { break }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    if let event = try? JSONDecoder().decode(ProxyGuardianEvent.self, from: line) {
                        Task { @MainActor [weak self] in self?.receive(event) }
                    }
                }
            }
            try? reader.close()
        }
    }
    private func receive(_ event: ProxyGuardianEvent) {
        onEvent?(event)
        guard let continuation = pending.removeValue(forKey: event.identifier) else { return }
        if event.success { continuation.resume(returning: event) }
        else { continuation.resume(throwing: ProxyFailure.message(event.message)) }
    }
    func send(_ request: ProxyGuardianRequest) async throws -> ProxyGuardianEvent {
        guard let input, isRunning else { throw ProxyFailure.message("核心监管程序未运行。") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.identifier] = continuation
            do {
                var data = try JSONEncoder().encode(request); data.append(10)
                try input.write(contentsOf: data)
            } catch { pending.removeValue(forKey: request.identifier)?.resume(throwing: error); return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                self?.pending.removeValue(forKey: request.identifier)?.resume(throwing: ProxyFailure.message("监管请求超时；请检查系统授权窗口或重新停止代理。"))
            }
        }
    }
    func sendTunnel(_ handle: FileHandle, root: URL) throws {
        guard isRunning, VPTSendFD(ProxyGuardianSocket.path(root: root), handle.fileDescriptor) == 0 else { throw ProxyFailure.message("无法向核心监管程序传递 TUN 会话。") }
    }
    func close() { try? input?.close(); input = nil }
}
