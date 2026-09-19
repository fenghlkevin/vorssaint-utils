// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import ServiceManagement
import ProxyTunnelBridge

@MainActor
final class ProxyGuardianClient {
    private var root: URL?
    // Retain standalone test processes; production lifetime is owned by launchd.
    private var testProcess: Process?
    var onEvent: ((ProxyGuardianEvent) -> Void)?
    var isRunning: Bool {
        guard let root else { return false }
        let fd = VPTControlConnect(ProxyGuardianSocket.controlPath(root: root))
        guard fd >= 0 else { return false }; Darwin.close(fd); return true
    }
    func connect(root: URL) { self.root = root }
    func launch(executable: URL, root: URL) async throws {
        self.root = root
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ProxyFailure.message("构建缺少代理后台服务。") }
        try ProxyFiles.directory(root)
        let plist = ProxyGuardianSocket.serviceID + ".plist"
        if FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/" + plist).path) {
            let service = SMAppService.agent(plistName: plist)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let key = "proxyAgentRegisteredVersion"
            if isRunning {
                let current = try await send(.init(command: "status"))
                // Preserve a live session across updates. Refresh on the next explicit restart.
                if current.corePID != nil || UserDefaults.standard.string(forKey: key) == version { return }
            }
            if service.status == .enabled, UserDefaults.standard.string(forKey: key) != version {
                try await service.unregister()
            }
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            guard service.status == .enabled else { throw ProxyFailure.message("请在系统设置 → 通用 → 登录项中允许 Vorssaint 后台运行，再启动代理。") }
            UserDefaults.standard.set(version, forKey: key)
        } else {
            if isRunning { return }
            // Unbundled integration tests. No pipe ties the child to the test/UI process.
            guard Bundle.main.bundleURL.pathExtension != "app" else { throw ProxyFailure.message("应用缺少后台服务注册文件，请重新安装。") }
            let process = Process()
            process.executableURL = executable; process.arguments = [root.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); testProcess = process
        }
    }
    func send(_ request: ProxyGuardianRequest) async throws -> ProxyGuardianEvent {
        guard let root else { throw ProxyFailure.message("代理后台尚未连接。") }
        let path = ProxyGuardianSocket.controlPath(root: root)
        let event = try await Task.detached(priority: .userInitiated) {
            var fd: Int32 = -1
            for _ in 0..<50 {
                fd = VPTControlConnect(path)
                if fd >= 0 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard fd >= 0 else { throw ProxyFailure.message("无法连接代理后台服务，请检查系统后台运行权限。") }
            defer { Darwin.close(fd) }
            try ProxyGuardianTransport.write(request, to: fd)
            return try JSONDecoder().decode(ProxyGuardianEvent.self, from: ProxyGuardianTransport.read(fd))
        }.value
        onEvent?(event)
        guard event.success else { throw ProxyFailure.message(event.message) }
        return event
    }
    func close() { root = nil }
}
