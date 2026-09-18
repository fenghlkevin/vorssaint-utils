// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import Darwin
import ProxyTunnelBridge

// This unprivileged supervisor outlives the UI. Authorization is scoped to
// SystemConfiguration; it never accepts arbitrary shell commands or runs as root.
umask(0o077)
signal(SIGPIPE, SIG_IGN)
guard CommandLine.arguments.count == 2 else { exit(64) }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let fm = FileManager.default
try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let lockFD = open(root.appendingPathComponent("guardian.lock").path, O_CREAT | O_RDWR, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(73) }
let lease = try ProxySystemLease(store: SCProxyNetworkStore(), journal: root.appendingPathComponent("system-proxy.plist"))
let socketPath = ProxyGuardianSocket.path(root: root)
let descriptorSocket = VPTBindFDReceiver(socketPath)
guard descriptorSocket >= 0 else { exit(74) }
var tunPID: Int32?
var core: Process?
func coreRunning() -> Bool {
    if let pid = tunPID { if VPTPollChild(pid) == 1 { return true }; tunPID = nil; return false }
    return core?.isRunning == true
}
var coreIdentifier: Int32? { tunPID ?? core?.processIdentifier }

var wantProxy = false
var proxyPort = 7890
var quitting = false
let outputLock = NSLock()
func emit(_ event: ProxyGuardianEvent) {
    guard var data = try? JSONEncoder().encode(event) else { return }
    data.append(10)
    outputLock.lock(); defer { outputLock.unlock() }
    try? FileHandle.standardOutput.write(contentsOf: data)
}
@Sendable func stopCore() {
    if let pid = tunPID {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while VPTPollChild(pid) == 1 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if VPTPollChild(pid) == 1 { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        tunPID = nil
    }
    guard let process = core, process.isRunning else { core = nil; return }
    process.terminate()
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    core = nil
}
func shutdown() {
    guard !quitting else { return }; quitting = true
    do { try lease.restore() } catch {
        emit(.init(identifier: "shutdown", success: false, message: "系统代理自动恢复未完成，请在网络设置中检查代理。"))
    }
    stopCore()
    unlink(socketPath); Darwin.close(descriptorSocket)
    exit(0)
}
func handle(_ request: ProxyGuardianRequest) {
    do {
        switch request.command {
        case "recover":
            guard core == nil && tunPID == nil else { throw ProxyNetworkError(message: "核心运行中，不能执行启动恢复。") }
            try lease.restore()
        case "start":
            guard core == nil && tunPID == nil, let executable = request.corePath, let work = request.workPath,
                  let config = request.configPath else { throw ProxyNetworkError(message: "核心启动参数无效。") }
            let working = URL(fileURLWithPath: work).standardizedFileURL.resolvingSymlinksInPath()
            let file = URL(fileURLWithPath: config).standardizedFileURL.resolvingSymlinksInPath()
            guard working.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  file.path.hasPrefix(working.path + "/"), executable.hasSuffix("mihomo-darwin-arm64") || executable.hasSuffix("mihomo-darwin-amd64") else {
                throw ProxyNetworkError(message: "核心工作目录无效。")
            }
            try lease.restore()
            if let expected = request.tunInterface {
                let fd = VPTReceiveFD(descriptorSocket)
                guard fd >= 0 else { throw ProxyNetworkError(message: "未收到 TUN 文件描述符。") }
                defer { Darwin.close(fd) }
                var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard VPTName(fd, &name, name.count) == 0, String(cString: name) == expected else { throw ProxyNetworkError(message: "TUN 网卡与会话不匹配。") }
                var pid: Int32 = 0
                guard VPTSpawn(executable, working.path, file.path, fd, &pid) == 0 else { throw ProxyNetworkError(message: "无法启动 TUN 核心。") }
                tunPID = pid
                break
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-d", working.path, "-f", file.path]
            process.currentDirectoryURL = working
            // Prevent proxy environment variables from causing a bootstrap loop.
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            core = process
        case "system":
            guard coreRunning(), let port = request.mixedPort, (1024...65535).contains(port) else { throw ProxyNetworkError(message: "请先启动核心。") }
            if request.systemProxy == true { try lease.enable(port: port); proxyPort = port; wantProxy = true }
            else { wantProxy = false; try lease.restore() }
        case "stop":
            wantProxy = false
            try lease.restore() // Keep the core alive if restoration fails; the UI can retry.
            stopCore()
        case "exit": shutdown()
        default: throw ProxyNetworkError(message: "不支持的监管请求。")
        }
        emit(.init(identifier: request.identifier, success: true, message: "ok", corePID: coreIdentifier, systemProxy: lease.ownedService != nil))
    } catch {
        emit(.init(identifier: request.identifier, success: false, message: error.localizedDescription, corePID: coreIdentifier, systemProxy: lease.ownedService != nil))
    }
}
let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    if (core != nil || tunPID != nil) && !coreRunning() {
        wantProxy = false
        do { try lease.restore() } catch {
            emit(.init(identifier: "fault", success: false, message: "核心退出且代理恢复失败，请检查系统网络代理。"))
            core = nil; return
        }
        core = nil
        emit(.init(identifier: "fault", success: false, message: "核心意外退出，系统代理已恢复。"))
    } else if wantProxy {
        do { try lease.enable(port: proxyPort) }
        catch {
            wantProxy = false
            do { try lease.restore() } catch { /* Journal retained for recovery. */ }
            emit(.init(identifier: "network", success: false, message: "网络发生变化，系统代理接管已暂停；请重新开启。", corePID: coreIdentifier, systemProxy: lease.ownedService != nil))
        }
    }
}
// Closing the inherited pipe detects UI crashes and SIGKILL without PID-reuse races.
DispatchQueue.global(qos: .utility).async {
    var buffer = Data()
    while true {
        let data = FileHandle.standardInput.availableData
        if data.isEmpty { DispatchQueue.main.async { shutdown() }; return }
        buffer.append(data)
        if buffer.count > 65536 { DispatchQueue.main.async { shutdown() }; return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if let request = try? JSONDecoder().decode(ProxyGuardianRequest.self, from: line) {
                DispatchQueue.main.async { handle(request) }
            }
        }
    }
}
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { shutdown() }; term.resume()
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { shutdown() }; interrupt.resume()
RunLoop.main.run()
