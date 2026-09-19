// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ServiceManagement

/// Separate XPC connection and heartbeat from TUN. Authorizing the helper never creates a tunnel.
@MainActor final class ProxySystemClient {
    private let background: Bool
    init(background: Bool = false) { self.background = background }
    private var connection: NSXPCConnection?
    private var pulse: Task<Void, Never>?
    var onStatus: ((Bool, String) -> Void)?
    var onFailure: ((String) -> Void)?
    var available: Bool {
        Bundle.main.bundleIdentifier != nil && SMAppService.daemon(plistName: ProxyTunnelIdentifiers.plistName).status == .enabled
    }
    private func transport() throws -> NSXPCConnection {
        if let connection { return connection }
        guard background || available, let requirement = ProxyTunnelIdentifiers.requirement(for: ProxyTunnelIdentifiers.helperID) else {
            throw ProxyFailure.message("请先授权网络助手，并在 macOS 登录项中批准。")
        }
        let channel = NSXPCConnection(machServiceName: ProxyTunnelIdentifiers.helperID, options: .privileged)
        channel.setCodeSigningRequirement(requirement)
        channel.remoteObjectInterface = ProxyTunnelIdentifiers.interface()
        channel.invalidationHandler = { [weak self, weak channel] in Task { @MainActor in
            guard let self, self.connection === channel else { return }
            self.connection = nil; self.pulse?.cancel(); self.onFailure?("网络助手连接中断，系统代理正在恢复。")
        } }
        channel.interruptionHandler = { [weak self] in Task { @MainActor in
            self?.onFailure?("网络助手已中断，系统代理需要重新启动。")
        } }
        channel.resume(); connection = channel; return channel
    }
    private func request(_ enabled: Bool?, port: Int = 0) async throws -> ProxyTunnelReply {
        let channel = try transport()
        let result: ProxyTunnelReply = try await withCheckedThrowingContinuation { continuation in
            let gate = ProxyReplyGate<ProxyTunnelReply>(continuation)
            guard let proxy = channel.remoteObjectProxyWithErrorHandler({ gate.fail($0) }) as? ProxyTunnelXPCProtocol else {
                gate.fail(ProxyFailure.message("网络助手不可用。")); return
            }
            let reply: (Data) -> Void = { data in
                guard let value = try? JSONDecoder().decode(ProxyTunnelReply.self, from: data), value.success, value.systemProxy != nil else {
                    gate.fail(ProxyFailure.message((try? JSONDecoder().decode(ProxyTunnelReply.self, from: data))?.message ?? "网络助手版本不兼容。")); return
                }
                gate.succeed(value)
            }
            if let enabled { proxy.systemProxy(enabled, port: port, withReply: reply) }
            else { proxy.systemHeartbeat(withReply: reply) }
        }
        onStatus?(result.systemProxy == true, result.message)
        return result
    }
    func enable(port: Int) async throws {
        let result = try await request(true, port: port)
        guard result.systemProxy == true else { throw ProxyFailure.message("系统代理未生效。") }
        pulse?.cancel()
        pulse = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self else { return }
                do {
                    let result = try await self.request(nil)
                    if result.systemProxy != true { return }
                } catch { self.onFailure?(error.localizedDescription); self.connection?.invalidate(); return }
            }
        }
    }
    func stop() async throws {
        pulse?.cancel(); pulse = nil
        guard connection != nil else { return }
        do { _ = try await request(false) }
        catch { connection?.invalidate(); throw error }
    }
}
