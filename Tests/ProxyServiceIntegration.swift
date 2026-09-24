// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
@main struct ProxyServiceIntegration {
    @MainActor static func wait(_ service: ProxyService) async throws {
        let deadline = Date().addingTimeInterval(30)
        while service.busy && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(!service.busy, "service operation timed out")
    }
    @MainActor static func main() async throws {
        precondition(ProxyService.isTransientStartupFailure(ProxyFailure.message("没有可用的物理网络服务，系统代理未开启。")))
        precondition(ProxyService.isTransientStartupFailure(URLError(.notConnectedToInternet)))
        precondition(!ProxyService.isTransientStartupFailure(ProxyFailure.message("请先授权网络助手")))
        precondition(!ProxyService.isTransientStartupFailure(ProxyFailure.message("端口 7890 已被占用")))
        precondition(!ProxyService.isTransientStartupFailure(CancellationError()))
        let slowInspection = try ProxyConfigCompiler.inspect(Data("proxies: []\nproxy-groups: []\nrule-providers: {slow: {type: http, behavior: classical, url: 'http://127.0.0.1:27181/slow', interval: 3600}}\nrules: ['RULE-SET,slow,DIRECT', 'MATCH,DIRECT']\n".utf8))
        let slowWork = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: slowWork) }
        let loading = Task { try await ProxyResources.prepare(slowInspection, work: slowWork) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelledAt = Date(); loading.cancel()
        do { try await loading.value; fatalError("cancelled resource download succeeded") }
        catch { precondition(error is CancellationError, "resource cancellation must propagate") }
        precondition(Date().timeIntervalSince(cancelledAt) < 3, "resource cancellation took too long")
        print("Slow resource download cancellation passed")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let core = URL(fileURLWithPath: CommandLine.arguments[2])
        let guardian = URL(fileURLWithPath: CommandLine.arguments[3])
        let store = ProxyProfileStore(root: root)
        let source = "proxies: []\nproxy-groups: [{name: Proxy, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,DIRECT']\n"
        let first = try store.importProfile(data: Data(source.utf8), name: "first")
        let second = try store.importProfile(data: Data(source.utf8), name: "second")
        var prefs = ProxyPreferences(); prefs.systemProxy = false; prefs.mixedPort = 27890; prefs.controllerPort = 29090; prefs.dnsPort = 21053
        try store.save(prefs)
        var service = ProxyService(root: root, core: core, guardian: guardian)
        let initiallyNeedsConfirmation = try await service.needsQuitConfirmation()
        precondition(!initiallyNeedsConfirmation, "stopped proxy must not prompt on quit")
        service.setSystemProxy(true)
        service.start(); try await wait(service)
        precondition(service.state == .stopped && service.error?.contains("授权网络助手") == true,
                     "missing helper must fail before privileged startup")
        service.removeTunnelHelper(); try await wait(service)
        precondition(service.error == nil && !service.preferences.systemProxy && !service.preferences.tunnelSettings.enabled,
                     "removal must disable privileged features even when helper is absent")
        service.removeTunnelHelper(); try await wait(service)
        precondition(service.error == nil, "repeated removal must be idempotent")
        print("Missing-helper startup and repeated removal passed")
        service.start(); try await wait(service)
        precondition(service.state == .running, service.error ?? "start failed")
        let runningNeedsConfirmation = try await service.needsQuitConfirmation()
        precondition(runningNeedsConfirmation, "running core must prompt even without system proxy")
        let wasRunningBeforeTunnel = try await service.needsQuitConfirmation()
        service.setTunnel(true); try await wait(service)
        precondition(service.state == .running && !service.preferences.tunnelSettings.enabled,
                     "failed TUN preflight must preserve running proxy")
        precondition(service.error?.contains("授权网络助手") == true && wasRunningBeforeTunnel,
                     "missing helper must be rejected before restarting core")
        let telemetry = service.telemetry
        telemetry.logLevel = "info"
        telemetry.setVisible("test", true)
        try await Task.sleep(nanoseconds: 800_000_000)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { fatalError("socket") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(27890).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        precondition(connected == 0)
        let handshake = "CONNECT 127.0.0.1:27181 HTTP/1.1\r\nHost: 127.0.0.1:27181\r\n\r\n"
        _ = handshake.withCString { Darwin.send(fd, $0, strlen($0), 0) }
        var reply = [UInt8](repeating: 0, count: 4096)
        let received = Darwin.recv(fd, &reply, reply.count, 0)
        precondition(received > 0 && String(decoding: reply.prefix(max(0, received)), as: UTF8.self).contains("200"))
        let get = "GET / HTTP/1.1\r\nHost: fixture\r\n\r\n"
        _ = get.withCString { Darwin.send(fd, $0, strlen($0), 0) }
        let reader = Task.detached { var buffer = [UInt8](repeating: 0, count: 32768); while Darwin.recv(fd, &buffer, buffer.count, 0) > 0 {} }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        precondition(telemetry.connectionCount > 0 && telemetry.downloadTotal > 0 && telemetry.downloadRate > 0, "real traffic missing")
        precondition(telemetry.logs.contains { $0.message.contains("27181") }, "real core log missing")
        let diagnostic = String(decoding: try service.diagnosticData(), as: UTF8.self)
        precondition(!diagnostic.contains("fixture") && !diagnostic.contains("127.0.0.1") && !diagnostic.contains("first"), "diagnostic exposed identifiers")
        precondition(telemetry.connections.contains { $0.process == "test" }, "local client process was not resolved")
        let connectionID = telemetry.connections.first!.id
        try await telemetry.closeConnection(connectionID)
        await reader.value
        try await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(!telemetry.connections.contains { $0.id == connectionID }, "connection did not close")
        telemetry.setVisible("test", false)
        precondition(telemetry.sampleDate == nil)
        let historyCount = telemetry.history.count
        try await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(telemetry.history.count == historyCount, "hidden view kept polling")
        print("Real loopback traffic, connection termination, log stream, diagnostic privacy and hidden-view suspension passed")
        service.editorYAML = source + "unsupported: true\n"
        service.saveDraft(); service.applyDraft(); try await wait(service)
        precondition(service.state == .running && service.selectedID == first.id && service.error != nil, "invalid draft disturbed running config")
        let committed = try store.committed(first.id)
        precondition(committed.yaml == source, "invalid draft committed")
        service.editorYAML = source.replacingOccurrences(of: "['MATCH,DIRECT']", with: "['DOMAIN,example.invalid,REJECT', 'MATCH,DIRECT']")
        service.saveDraft(); service.applyDraft(); try await wait(service)
        precondition(service.state == .running && service.error == nil && service.inspection?.ruleCount == 2, service.error ?? "valid apply failed")
        service.selectProfile(second.id); try await wait(service)
        precondition(service.state == .running && service.selectedID == second.id, service.error ?? "switch failed")
        service.reloadProfile(); try await wait(service)
        precondition(service.state == .running && service.error == nil, service.error ?? "reload failed")
        service.selectProfile(first.id); try await wait(service)
        guard let original = service.revisionHistory.first(where: { $0.draft.yaml == source }) else { fatalError("missing baseline history") }
        service.rollback(original); try await wait(service)
        precondition(service.state == .running && service.inspection?.ruleCount == 1, service.error ?? "rollback failed")
        service.reloadProfile()
        let stoppingService = service
        async let stoppedFirst = stoppingService.stopAndWait()
        async let stoppedSecond = stoppingService.stopAndWait()
        let stopped = await (stoppedFirst, stoppedSecond)
        precondition(stopped.0 && stopped.1 && service.state == .stopped, "concurrent stop failed")
        service.start(); try await wait(service)
        precondition(service.state == .running, service.error ?? "restart after cancellation failed")
        try await telemetry.closeAll()
        for _ in 0..<5 { service.reloadProfile(); try await wait(service); precondition(service.state == .running) }
        telemetry.setVisible("soak", true)
        let soakSeconds = Int(ProcessInfo.processInfo.environment["PROXY_SOAK_SECONDS"] ?? "0") ?? 0
        for _ in 0..<min(soakSeconds, 600) {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            precondition(service.state == .running && telemetry.issue == nil)
            precondition(telemetry.history.count <= 60 && telemetry.logs.count <= 1000)
        }
        if soakSeconds > 0 {
            precondition((telemetry.memory ?? 0) > 0, "core memory stream missing")
            print("Visible telemetry soak passed: \(min(soakSeconds, 600)) seconds; core memory \(Int(telemetry.memory ?? 0)) bytes")
        }
        telemetry.setVisible("soak", false)
        let controller = ProxyGuardianClient()
        try await controller.launch(executable: guardian, root: root)
        let before = try await controller.send(.init(command: "status"))
        await service.detachForQuit()
        service = ProxyService(root: root, core: core, guardian: guardian)
        service.sync(enabled: true); try await wait(service)
        precondition(service.state == .running && service.selectedID == first.id, service.error ?? "reattach failed")
        let after = try await controller.send(.init(command: "status"))
        precondition(before.corePID == after.corePID && after.committed, "reopening restarted core")
        print("Service reopen recovered live profile and attached to the same core PID")
        service.disableTunnelAndStop()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await wait(service)
        precondition(service.state == .stopped && !service.preferences.tunnelSettings.enabled, "emergency TUN stop failed")
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(service.state == .stopped, "emergency stop restarted proxy")
        let finalStop = await service.stopAndWait(); precondition(finalStop)
        _ = try await controller.send(.init(command: "exit"))
        await telemetry.finishArchive()
        print("Real-core live draft validation, failure preservation, apply, profile switch, reload and historical rollback, cancellation and concurrent stop passed")
    }
}
