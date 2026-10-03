// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ServiceManagement

@MainActor final class HostsHelperClient {
    private var connection: NSXPCConnection?
    private var verified = false
    private var service: SMAppService { .daemon(plistName: ProxyTunnelIdentifiers.plistName) }
    var accessText: String {
        switch service.status {
        case .enabled: return verified ? "已授权，连接已验证" : "已授权（连接待验证）"
        case .requiresApproval: return "等待系统批准"
        case .notRegistered: return "未授权"
        default: return "助手未注册或不可用"
        }
    }
    var enabled: Bool { service.status == .enabled }
    func authorize() async throws {
        guard ProxyTunnelIdentifiers.embeddedCodeHash() != nil else { throw HostsFailure(message: "无法验证应用内网络助手的签名。") }
        if service.status == .notRegistered || service.status == .notFound { try service.register() }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw HostsFailure(message: "请在 macOS 登录项中批准网络助手，再点击“授权 / 更新助手”。")
        }
        try await ensureCurrent()
    }
    func ensureCurrent() async throws {
        guard enabled else { throw HostsFailure(message: "请先授权网络助手，并在 macOS 登录项中批准。") }
        let expected = ProxyTunnelIdentifiers.embeddedCodeHash()
        let system = try await status(tunnel: false)
        guard try HostsHelperPolicy.needsReplacement(expectedHash: expected, runningHash: system.helperCodeHash) else { verified = true; return }
        guard system.success, system.systemProxy == false else { throw HostsFailure(message: "网络助手为旧版且系统代理正在使用它。请先停止网络代理，再更新助手。") }
        let tunnel = try await status(tunnel: true)
        guard tunnel.success, HostsHelperPolicy.canReplace(systemProxy: system.systemProxy, tunnelActive: tunnel.active, tunnelInterface: tunnel.interface) else {
            throw HostsFailure(message: "网络助手为旧版且 TUN 会话尚未结束。请先停止网络代理，再更新助手。")
        }
        close()
        try await service.unregister()
        try service.register()
        guard enabled else {
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            throw HostsFailure(message: "网络助手已更新，请在 macOS 登录项中批准后重试。")
        }
        let updated = try await status(tunnel: false)
        guard try !HostsHelperPolicy.needsReplacement(expectedHash: expected, runningHash: updated.helperCodeHash) else {
            close(); throw HostsFailure(message: "新版网络助手尚未启动，请稍后点击“授权 / 更新助手”重试。")
        }
        verified = true
    }
    private func proxy(_ failure: @escaping (Error) -> Void) throws -> ProxyTunnelXPCProtocol {
        if connection == nil {
            guard let requirement = ProxyTunnelIdentifiers.requirement(for: ProxyTunnelIdentifiers.helperID) else { throw HostsFailure(message: "无法校验网络助手签名。") }
            let channel = NSXPCConnection(machServiceName: ProxyTunnelIdentifiers.helperID, options: .privileged)
            channel.setCodeSigningRequirement(requirement); channel.remoteObjectInterface = ProxyTunnelIdentifiers.interface()
            channel.resume(); connection = channel
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler(failure) as? ProxyTunnelXPCProtocol else { throw HostsFailure(message: "网络助手不可用。") }
        return proxy
    }
    private func status(tunnel: Bool) async throws -> ProxyTunnelReply {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ProxyReplyGate<ProxyTunnelReply>(continuation)
            do {
                let proxy = try proxy { gate.fail($0) }
                let reply: (Data) -> Void = { data in
                    do { gate.succeed(try JSONDecoder().decode(ProxyTunnelReply.self, from: data)) }
                    catch { gate.fail(HostsFailure(message: "无法读取网络助手状态，未更改助手注册。")) }
                }
                // Both selectors predate Hosts. Inspect the lease fields even
                // when success=false (another connection owns the session).
                if tunnel { proxy.heartbeat(withReply: reply) }
                else { proxy.systemHeartbeat(withReply: reply) }
            } catch { gate.fail(error) }
        }
    }
    func write(_ request: HostsWriteRequest) async throws -> HostsWriteReply {
        try await ensureCurrent()
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ProxyReplyGate<HostsWriteReply>(continuation)
            do {
                let proxy = try proxy { gate.fail($0) }
                proxy.applyHosts(data) { data in
                    do { gate.succeed(try JSONDecoder().decode(HostsWriteReply.self, from: data)) }
                    catch { gate.fail(HostsFailure(message: "网络助手返回了无效的 Hosts 写入结果，请刷新后检查。")) }
                }
            } catch { gate.fail(error) }
        }
    }
    func close() { connection?.invalidate(); connection = nil; verified = false }

    /// Signed app entrypoint for verifying/updating the helper independently of
    /// startup services. It never writes Hosts or changes a proxy configuration.
    nonisolated static func diagnoseAndExit(repair: Bool) -> Never {
        Task { @MainActor in
            let client = HostsHelperClient()
            do {
                if repair { try await client.authorize() }
                else {
                    guard client.enabled else { throw HostsFailure(message: client.accessText) }
                    let state = try await client.status(tunnel: false)
                    let stale = try HostsHelperPolicy.needsReplacement(expectedHash: ProxyTunnelIdentifiers.embeddedCodeHash(), runningHash: state.helperCodeHash)
                    print("Hosts helper: \(stale ? "outdated" : "current"), systemProxy=\(String(describing: state.systemProxy))")
                    if stale { client.close(); exit(2) }
                }
                print("Hosts helper signature/protocol verified; /etc/hosts untouched")
                client.close(); exit(0)
            } catch { print("Hosts helper: \(error.localizedDescription)"); client.close(); exit(1) }
        }
        RunLoop.main.run(); exit(1)
    }
}
