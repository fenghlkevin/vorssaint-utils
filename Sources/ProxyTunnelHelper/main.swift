// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import ProxyTunnelBridge
import SystemConfiguration

final class TunnelNetwork: ProxyTunnelNetwork {
    func snapshot(excluding: String?) throws -> ProxyNetworkSnapshot { try .read(excluding: excluding) }
    func create(ipv6: Bool) throws -> (ProxyTunnelIdentity, Int32) {
        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let fd = VPTCreate(&name, name.count)
        guard fd >= 0 else { throw ProxyTunnelError(message: "无法创建 macOS TUN 网卡。") }
        let interface = String(cString: name)
        let subnet = UInt32.random(in: 1...32000) * 4
        let address = "198.\(18 + (subnet >> 16)).\((subnet >> 8) & 255).\((subnet & 255) + 1)"
        let v6 = ipv6 ? "fd7a:7654:\(String(subnet, radix: 16))::1" : nil
        let identity = ProxyTunnelIdentity(name: interface, index: if_nametoindex(interface), ipv4: address, ipv6: v6)
        do {
            _ = try ProxyNetworkCommand.run("/sbin/ifconfig", [interface, "inet", address, address, "netmask", "255.255.255.252", "mtu", "1500", "up"])
            if let v6 { _ = try ProxyNetworkCommand.run("/sbin/ifconfig", [interface, "inet6", v6, "prefixlen", "126", "alias"]) }
        } catch { Darwin.close(fd); throw error }
        return (identity, fd)
    }
    func owns(_ identity: ProxyTunnelIdentity) -> Bool {
        guard if_nametoindex(identity.name) == identity.index else { return false }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return false }
        defer { freeifaddrs(first) }
        var current = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == identity.name, let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0, String(cString: text) == identity.ipv4 { return true }
        }
        return false
    }
    func add(_ route: ProxyCIDR, to identity: ProxyTunnelIdentity) throws {
        guard owns(identity) else { throw ProxyTunnelError(message: "网卡归属校验失败。") }
        let snapshot = try self.snapshot(excluding: nil)
        guard !snapshot.routes.contains(where: { $0.prefix == route }) else { throw ProxyTunnelError(message: "候选路由已被其他网络服务占用。") }
        _ = try ProxyNetworkCommand.run("/sbin/route", ["-n", "add", route.isIPv6 ? "-inet6" : "-inet", "-net", route.description, "-interface", identity.name])
    }
    func remove(_ route: ProxyCIDR, from identity: ProxyTunnelIdentity) throws {
        guard owns(identity) else { return }
        let existing = try snapshot(excluding: nil).routes
        guard existing.contains(where: { $0.prefix == route && $0.interface == identity.name }) else { return }
        _ = try ProxyNetworkCommand.run("/sbin/route", ["-n", "delete", route.isIPv6 ? "-inet6" : "-inet", "-net", route.description, "-interface", identity.name])
    }
    func close(_ descriptor: Int32, identity: ProxyTunnelIdentity) {
        if owns(identity) { _ = try? ProxyNetworkCommand.run("/sbin/ifconfig", [identity.name, "down"]) }
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}

final class TunnelController {
    let queue = DispatchQueue(label: "com.vorssaint.proxy-tun")
    private let lease = ProxyTunnelLease(backend: TunnelNetwork(), journal: URL(fileURLWithPath: "/var/run/vorssaint-proxy-tun.json"))
    private var owner: UUID?
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var issue = ""
    private var timer: DispatchSourceTimer?
    init() {
        queue.async { try? self.lease.recover() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                if self.owner != nil && ProcessInfo.processInfo.systemUptime - self.heartbeat > 15 { try self.lease.restore(); self.owner = nil; self.issue = "客户端心跳超时，TUN 已恢复。" }
                else { try self.lease.checkNetwork() }
            } catch { self.issue = error.localizedDescription }
        }
        timer.resume(); self.timer = timer
    }
    private func status(success: Bool = true) -> ProxyTunnelReply { .init(success: success, active: lease.active, interface: lease.identity?.name, routeCount: lease.routeCount, address4: lease.identity?.ipv4, address6: lease.identity?.ipv6, message: issue) }
    func prepare(id: UUID, data: Data, reply: @escaping (FileHandle?, Data) -> Void) {
        queue.async {
            do {
                guard self.owner == nil, data.count <= 65536 else { throw ProxyTunnelError(message: "增强模式正在被另一会话使用。") }
                let plan = try JSONDecoder().decode(ProxyTunnelPlan.self, from: data)
                try self.lease.prepare(plan)
                self.owner = id; self.heartbeat = ProcessInfo.processInfo.systemUptime; self.issue = ""
                let duplicate = dup(self.lease.descriptor)
                guard duplicate >= 0 else { throw ProxyTunnelError(message: "无法传递 TUN 文件描述符。") }
                reply(FileHandle(fileDescriptor: duplicate, closeOnDealloc: true), self.status().encoded)
            } catch { if self.owner == id { try? self.lease.restore(); self.owner = nil }; self.issue = error.localizedDescription; reply(nil, self.status(success: false).encoded) }
        }
    }
    func command(_ command: String, id: UUID, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                guard self.owner == nil || self.owner == id else { throw ProxyTunnelError(message: "无权操作另一会话。") }
                switch command {
                case "activate": guard self.owner == id else { throw ProxyTunnelError(message: "请先准备 TUN。") }; try self.lease.activate()
                case "heartbeat": self.heartbeat = ProcessInfo.processInfo.systemUptime
                case "stop": try self.lease.restore(); self.owner = nil; self.issue = ""
                default: throw ProxyTunnelError(message: "不支持的操作。")
                }
                reply(self.status().encoded)
            } catch { self.issue = error.localizedDescription; reply(self.status(success: false).encoded) }
        }
    }
    func disconnected(_ id: UUID) { command("stop", id: id) { _ in } }
    func shutdown() { queue.async { do { try self.lease.restore(); exit(0) } catch { self.issue = error.localizedDescription } } }
}
final class SystemProxyController {
    let queue = DispatchQueue(label: "vorssaint.system-proxy-helper")
    let session: ProxySystemSession
    private let timer: DispatchSourceTimer
    init() {
        do {
            session = try ProxySystemSession(lease: ProxySystemLease(store: SCProxyNetworkStore(), journal: URL(fileURLWithPath: "/var/run/" + ProxyTunnelIdentifiers.helperID + "-system.plist")))
        } catch { exit(74) }
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.session.tick(now: ProcessInfo.processInfo.systemUptime) }
        timer.resume()
    }
    func request(_ id: UUID, enabled: Bool?, port: Int = 0, reply: @escaping (Data) -> Void) {
        queue.async {
            var result = ProxyTunnelReply()
            do {
                if let enabled { try self.session.set(enabled, port: port, owner: id, now: ProcessInfo.processInfo.systemUptime) }
                else { try self.session.heartbeat(id, now: ProcessInfo.processInfo.systemUptime) }
            } catch { result.success = false; result.message = error.localizedDescription }
            result.systemProxy = self.session.active
            if result.message.isEmpty { result.message = self.session.issue }
            reply(result.encoded)
        }
    }
    func disconnected(_ id: UUID) { queue.async { try? self.session.stop(id) } }
    func restoreForShutdown() throws { try queue.sync { if let id = session.owner { try session.stop(id) } } }
}
final class TunnelSession: NSObject, ProxyTunnelXPCProtocol {
    let id = UUID(); let controller: TunnelController; let system: SystemProxyController
    init(_ controller: TunnelController, system: SystemProxyController) { self.controller = controller; self.system = system }
    func systemProxy(_ enabled: Bool, port: Int, withReply reply: @escaping (Data) -> Void) { system.request(id, enabled: enabled, port: port, reply: reply) }
    func systemHeartbeat(withReply reply: @escaping (Data) -> Void) { system.request(id, enabled: nil, reply: reply) }
    func prepare(_ plan: Data, withReply reply: @escaping (FileHandle?, Data) -> Void) { controller.prepare(id: id, data: plan, reply: reply) }
    func activate(withReply reply: @escaping (Data) -> Void) { controller.command("activate", id: id, reply: reply) }
    func heartbeat(withReply reply: @escaping (Data) -> Void) { controller.command("heartbeat", id: id, reply: reply) }
    func stop(withReply reply: @escaping (Data) -> Void) { controller.command("stop", id: id, reply: reply) }
}
final class TunnelDelegate: NSObject, NSXPCListenerDelegate {
    let controller = TunnelController()
    let system = SystemProxyController()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var consoleUID: uid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
        guard consoleUID != 0, connection.effectiveUserIdentifier == consoleUID else { return false }
        let session = TunnelSession(controller, system: system)
        connection.exportedInterface = ProxyTunnelIdentifiers.interface(); connection.exportedObject = session
        connection.invalidationHandler = { [weak controller, weak system] in controller?.disconnected(session.id); system?.disconnected(session.id) }
        connection.interruptionHandler = { [weak controller, weak system] in controller?.disconnected(session.id); system?.disconnected(session.id) }
        connection.resume(); return true
    }
}
if CommandLine.arguments.contains("--selftest") {
    let p = try ProxyCIDR("10.0.0.0/8")
    guard p.contains(try ProxyCIDR("10.2.3.4/32")), ProxyTunnelIdentifiers.requirement(for: ProxyTunnelIdentifiers.appID) != "" else { exit(1) }
    print("proxy-tun-helper: policy loaded (no network changes)"); exit(0)
}
umask(0o077)
guard geteuid() == 0, let requirement = ProxyTunnelIdentifiers.requirement(for: ProxyTunnelIdentifiers.appID) else { exit(1) }
let lock = open("/var/run/vorssaint-proxy-tun.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
var info = stat()
guard lock >= 0, fstat(lock, &info) == 0, info.st_uid == 0, info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(73) }
let journalPath = "/var/run/vorssaint-proxy-tun.json"
if lstat(journalPath, &info) == 0 { guard info.st_uid == 0, info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else { exit(74) } }
let systemJournal = "/var/run/" + ProxyTunnelIdentifiers.helperID + "-system.plist"
if lstat(systemJournal, &info) == 0 { guard info.st_uid == 0, info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else { exit(74) } }
let delegate = TunnelDelegate()
let listener = NSXPCListener(machServiceName: ProxyTunnelIdentifiers.helperID)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
signalSource.setEventHandler { do { try delegate.system.restoreForShutdown(); delegate.controller.shutdown() } catch { /* Keep serving and retry restoration on the next heartbeat tick. */ } }; signalSource.resume()
listener.resume(); RunLoop.main.run()
