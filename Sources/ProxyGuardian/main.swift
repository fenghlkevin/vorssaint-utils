// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import AppKit
import Darwin
import ProxyTunnelBridge

func bundledCoreURL(named name: String) throws -> URL {
    // launchd supplies a relative argv[0] for BundleProgram. Ask the kernel for
    // our actual executable instead of resolving argv[0] against the working directory.
    var path = [CChar](repeating: 0, count: 4096)
    guard VPTExecutablePath(&path, path.count) > 0 else { throw ProxyNetworkError(message: "无法确认代理后台服务安装位置。") }
    return URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/ProxyCore/" + name).resolvingSymlinksInPath()
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-bundled-core" {
    let candidate = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
    exit(try bundledCoreURL(named: candidate.lastPathComponent) == candidate ? 0 : 1)
}

/// Owns the core and privileged-helper leases independently of any UI connection.
@MainActor final class Guardian {
    let root: URL
    let lease: ProxySystemLease
    let system = ProxySystemClient(background: true)
    let tunnel = ProxyTunnelClient(background: true)
    var corePID: Int32?
    var preparedFD: FileHandle?
    var tunnelReply = ProxyTunnelReply()
    var helperSession = false
    var tunnelSession = false
    var wantProxy = false
    var proxyPort = 7890
    var configPath: String?
    var profileID: UUID?
    var committed = false
    var startingAt: Date?
    var issue = ""
    var handling = false
    var quitting = false
    var recoveryQueued = false
    var timer: Timer?
    var sleepObserver: NSObjectProtocol?
    var api: ProxyAPI?
    var failures = 0

    init(root: URL) throws {
        self.root = root
        lease = try ProxySystemLease(store: SCProxyNetworkStore(), journal: root.appendingPathComponent("system-proxy.plist"))
        try lease.restore()
        system.onStatus = { [weak self] active, message in
            self?.wantProxy = active
            if !message.isEmpty { self?.issue = message }
        }
        system.onFailure = { [weak self] message in
            guard let self else { return }
            self.recover(message)
        }
        tunnel.onStatus = { [weak self] reply in self?.tunnelReply = reply }
        tunnel.onFailure = { [weak self] message in
            guard let self else { return }
            self.recover(message)
        }
        // Preserve the existing conservative TUN sleep policy even without a UI.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tunnelSession else { return }
                self.recover("休眠前已停止增强模式；唤醒后请手动启动。")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }
    func recover(_ message: String) {
        guard !recoveryQueued else { return }
        recoveryQueued = true
        Task {
            let reply = await handle(.init(command: "stop"))
            issue = reply.success ? message : reply.message
            recoveryQueued = false
        }
    }
    var pid: Int32? { corePID }
    func running() -> Bool {
        if let pid = corePID { if VPTPollChild(pid) == 1 { return true }; corePID = nil; return false }
        return false
    }
    func stopCore() {
        if let pid = corePID {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(2)
            while VPTPollChild(pid) == 1 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if VPTPollChild(pid) == 1 { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
            corePID = nil
        }
        preparedFD = nil; configPath = nil; profileID = nil
        committed = false; startingAt = nil; api = nil; failures = 0
    }
    func stop() async throws {
        // Restore first: leave the core serving if restoration fails, so stopping can be retried.
        if helperSession { try await system.stop(); helperSession = false }
        if tunnelSession { try await tunnel.stop(); tunnelSession = false; tunnelReply = .init() }
        try lease.restore(); wantProxy = false
        stopCore()
    }
    func snapshot(_ id: String, success: Bool = true, message: String? = nil) -> ProxyGuardianEvent {
        .init(identifier: id, success: success, message: message ?? issue, corePID: pid,
              systemProxy: wantProxy, tunnel: tunnelReply, configPath: configPath,
              profileID: profileID, committed: committed)
    }
    func handle(_ request: ProxyGuardianRequest) async -> ProxyGuardianEvent {
        while handling { try? await Task.sleep(nanoseconds: 50_000_000) }
        handling = true; defer { handling = false }
        do {
            switch request.command {
            case "status": break
            case "recover":
                guard !running(), !tunnelSession else { throw ProxyNetworkError(message: "代理正在后台运行，不能恢复其网络设置。") }
                try lease.restore()
            case "prepare":
                guard !running(), !tunnelSession, let data = request.tunnelPlan else { throw ProxyNetworkError(message: "TUN 准备参数无效。") }
                startingAt = Date(); tunnelSession = true
                let result = try await tunnel.prepare(JSONDecoder().decode(ProxyTunnelPlan.self, from: data))
                preparedFD = result.0; tunnelReply = result.1
            case "start":
                guard !running(), let executable = request.corePath, let work = request.workPath, let config = request.configPath else { throw ProxyNetworkError(message: "核心启动参数无效或已有核心运行。") }
                let working = URL(fileURLWithPath: work).standardizedFileURL.resolvingSymlinksInPath()
                let file = URL(fileURLWithPath: config).standardizedFileURL.resolvingSymlinksInPath()
                guard working.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), file.path.hasPrefix(working.path + "/"),
                      executable.hasSuffix("mihomo-darwin-arm64") || executable.hasSuffix("mihomo-darwin-amd64") else { throw ProxyNetworkError(message: "核心工作目录无效。") }
                if CommandLine.arguments.count == 1 {
                    let bundled = try bundledCoreURL(named: URL(fileURLWithPath: executable).lastPathComponent)
                    guard bundled.resolvingSymlinksInPath().path == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path else { throw ProxyNetworkError(message: "只能运行应用内置的核心。") }
                }
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                guard let controller = object?["external-controller"] as? String, controller.hasPrefix("127.0.0.1:"),
                      let port = Int(controller.split(separator: ":").last ?? ""), let secret = object?["secret"] as? String else { throw ProxyNetworkError(message: "运行配置缺少本机控制接口。") }
                try lease.restore()
                if let expected = request.tunInterface {
                    guard let descriptor = preparedFD, tunnelReply.interface == expected else { throw ProxyNetworkError(message: "TUN 网卡与会话不匹配。") }
                    var child: Int32 = 0
                    guard VPTSpawn(executable, working.path, file.path, descriptor.fileDescriptor, &child) == 0 else { throw ProxyNetworkError(message: "无法启动 TUN 核心。") }
                    corePID = child; preparedFD = nil
                } else {
                    guard !tunnelSession else { throw ProxyNetworkError(message: "TUN 会话尚未完成。") }
                    var child: Int32 = 0
                    guard VPTSpawn(executable, working.path, file.path, -1, &child) == 0 else { throw ProxyNetworkError(message: "无法启动代理核心。") }
                    corePID = child
                }
                configPath = file.path; profileID = request.profileID; committed = false; startingAt = Date(); issue = ""
                api = ProxyAPI(port: port, secret: secret)
            case "activate": try await tunnel.activate()
            case "commit":
                guard running() else { throw ProxyNetworkError(message: "核心尚未运行。") }
                committed = true; startingAt = nil
            case "system":
                guard running(), let port = request.mixedPort, (1024...65535).contains(port) else { throw ProxyNetworkError(message: "请先启动核心。") }
                if request.useSystemHelper == true || helperSession {
                    if request.systemProxy == true { helperSession = true; try await system.enable(port: port) }
                    else { try await system.stop(); helperSession = false }
                } else if request.systemProxy == true { throw ProxyNetworkError(message: "请先授权网络助手，再开启系统代理。") }
                else { try lease.restore() }
                wantProxy = request.systemProxy == true; proxyPort = port
            case "stop": try await stop(); issue = ""
            case "exit": try await stop(); quitting = true
            default: throw ProxyNetworkError(message: "不支持的监管请求。")
            }
            return snapshot(request.identifier)
        } catch { return snapshot(request.identifier, success: false, message: error.localizedDescription) }
    }
    func check() async {
        guard !handling else { return }
        handling = true; defer { handling = false }
        do {
            if let startingAt, Date().timeIntervalSince(startingAt) > 120 {
                issue = "代理启动未完成，已恢复网络。"; try await stop(); return
            }
            if (configPath != nil || corePID != nil) && !running() {
                issue = "核心意外退出，已恢复网络。"; try await stop(); return
            }
            if wantProxy && !helperSession { try lease.enable(port: proxyPort) }
            if committed, let api {
                do { _ = try await api.request(["version"]); failures = 0 }
                catch { failures += 1 }
                if failures >= 3 { issue = "核心连续无响应，已停止代理并恢复网络。"; try await stop() }
            }
        } catch { issue = error.localizedDescription }
    }
}

umask(0o077); signal(SIGPIPE, SIG_IGN)
let root: URL
if CommandLine.arguments.count == 2 { root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL }
else {
    root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + ProxyTunnelIdentifiers.appID + "/Proxy", isDirectory: true)
}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let lockFD = open(root.appendingPathComponent("guardian.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
var lockInfo = stat()
guard lockFD >= 0, fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
      flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(73) }
let socketPath = ProxyGuardianSocket.controlPath(root: root)
let listener = VPTControlListen(socketPath)
guard listener >= 0 else { exit(74) }
let guardian = try MainActor.assumeIsolated { try Guardian(root: root) }
// Serial request handling; a disconnected client only loses its reply, never its proxy session.
DispatchQueue.global(qos: .utility).async {
    while true {
        let fd = VPTControlAccept(listener)
        if fd < 0 { continue }
        do {
            let request = try JSONDecoder().decode(ProxyGuardianRequest.self, from: ProxyGuardianTransport.read(fd))
            let completion = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let response = await guardian.handle(request)
                try? ProxyGuardianTransport.write(response, to: fd)
                completion.signal()
                if guardian.quitting { unlink(socketPath); exit(0) }
            }
            completion.wait()
        } catch { /* Bounded malformed/disconnected clients cannot stop the service. */ }
        Darwin.close(fd)
    }
}
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    Task { @MainActor in
        do { try await guardian.stop(); unlink(socketPath); exit(0) }
        catch { guardian.issue = error.localizedDescription }
    }
}; term.resume()
RunLoop.main.run()
