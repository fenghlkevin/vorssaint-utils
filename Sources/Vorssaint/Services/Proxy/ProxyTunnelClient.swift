// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ServiceManagement

@MainActor
final class ProxyTunnelClient {
    private let background: Bool
    init(background: Bool = false) { self.background = background }
    private var connection: NSXPCConnection?
    private var hasSession = false
    private var pulse: Task<Void, Never>?
    var onStatus: ((ProxyTunnelReply) -> Void)?
    var onFailure: ((String) -> Void)?
    private var service: SMAppService { .daemon(plistName: ProxyTunnelIdentifiers.plistName) }
    var accessText: String {
        guard Bundle.main.bundleIdentifier != nil else { return "不可用" }
        switch service.status { case .enabled: return "已授权"; case .requiresApproval: return "等待系统批准"; case .notRegistered: return "未安装"; default: return "不可用" }
    }
    func authorize() throws {
        guard ProxyTunnelIdentifiers.requirement(for: ProxyTunnelIdentifiers.helperID) != nil else { throw ProxyFailure.message("增强模式需要使用稳定证书签名的应用。") }
        if service.status == .notRegistered || service.status == .notFound { try service.register() }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    private func transport() throws -> NSXPCConnection {
        guard background || service.status == .enabled else { throw ProxyFailure.message("请先在增强模式设置中授权网络助手，并在 macOS 登录项中批准。") }
        if let connection { return connection }
        guard let requirement = ProxyTunnelIdentifiers.requirement(for: ProxyTunnelIdentifiers.helperID) else { throw ProxyFailure.message("无法校验网络助手签名。") }
        let channel = NSXPCConnection(machServiceName: ProxyTunnelIdentifiers.helperID, options: .privileged)
        channel.setCodeSigningRequirement(requirement)
        channel.remoteObjectInterface = ProxyTunnelIdentifiers.interface()
        channel.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil; self?.pulse?.cancel(); self?.onFailure?("网络助手连接中断，增强模式状态需要检查。") } }
        channel.interruptionHandler = { [weak self] in Task { @MainActor in self?.onFailure?("网络助手已中断，正在停止增强模式。") } }
        channel.resume(); connection = channel; return channel
    }
    func prepare(_ plan: ProxyTunnelPlan) async throws -> (FileHandle, ProxyTunnelReply) {
        let channel = try transport(), data = try JSONEncoder().encode(plan)
        let result: (FileHandle, ProxyTunnelReply) = try await withCheckedThrowingContinuation { continuation in
            let gate = ProxyReplyGate<(FileHandle, ProxyTunnelReply)>(continuation)
            let proxy = channel.remoteObjectProxyWithErrorHandler { gate.fail($0) } as? ProxyTunnelXPCProtocol
            guard let proxy else { gate.fail(ProxyFailure.message("网络助手不可用。")); return }
            proxy.prepare(data) { handle, data in
                guard let result = try? JSONDecoder().decode(ProxyTunnelReply.self, from: data), result.success, let handle else {
                    let result = try? JSONDecoder().decode(ProxyTunnelReply.self, from: data)
                    gate.fail(ProxyFailure.message(result?.message ?? "TUN 准备失败。")); return
                }
                gate.succeed((handle, result))
            }
        }
        hasSession = true
        startHeartbeat()
        return result
    }
    func command(_ command: String) async throws -> ProxyTunnelReply {
        let channel = try transport()
        let result: ProxyTunnelReply = try await withCheckedThrowingContinuation { continuation in
            let gate = ProxyReplyGate<ProxyTunnelReply>(continuation)
            let proxy = channel.remoteObjectProxyWithErrorHandler { gate.fail($0) } as? ProxyTunnelXPCProtocol
            guard let proxy else { gate.fail(ProxyFailure.message("网络助手不可用。")); return }
            let reply: (Data) -> Void = { data in
                guard let result = try? JSONDecoder().decode(ProxyTunnelReply.self, from: data), result.success else { gate.fail(ProxyFailure.message((try? JSONDecoder().decode(ProxyTunnelReply.self, from: data).message) ?? "TUN 操作失败。")); return }
                gate.succeed(result)
            }
            switch command { case "activate": proxy.activate(withReply: reply); case "stop": proxy.stop(withReply: reply); default: proxy.heartbeat(withReply: reply) }
        }
        onStatus?(result)
        return result
    }
    func activate() async throws {
        let result = try await command("activate")
        guard result.active else { throw ProxyFailure.message("TUN 路由没有生效。") }
        startHeartbeat()
    }
    func startHeartbeat() {
        pulse?.cancel()
        pulse = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self else { return }
                do { _ = try await self.command("heartbeat") } catch { self.onFailure?(error.localizedDescription); return }
            }
        }
    }
    func stop() async throws {
        pulse?.cancel(); pulse = nil
        guard connection != nil || hasSession else { return }
        _ = try await command("stop")
        hasSession = false
    }
    func unregister() async throws {
        try await stop()
        connection?.invalidate(); connection = nil
        // An already absent helper is a successful removal, not an OS error.
        if Bundle.main.bundleIdentifier != nil,
           service.status != .notRegistered, service.status != .notFound {
            try await service.unregister()
        }
        UserDefaults.standard.removeObject(forKey: "proxyTunnelHelperRegisteredVersion")
    }
}

/// XPC error, timeout and reply may race. Resume the continuation exactly once.
final class ProxyReplyGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { self.fail(ProxyFailure.message("网络助手请求超时。")) }
    }
    func succeed(_ value: Value) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<Value, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
}
