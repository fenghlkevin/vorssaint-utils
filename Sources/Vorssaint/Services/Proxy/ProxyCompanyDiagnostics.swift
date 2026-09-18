// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct ProxyNetworkCheck: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let succeeded: Bool
    let detail: String
}
enum ProxyCompanyDiagnostics {
    static func run(server: String, domain: String, port: Int) async -> [ProxyNetworkCheck] {
        await Task.detached(priority: .utility) {
            var result: [ProxyNetworkCheck] = []
            do {
                let serverIP = try ProxyCIDR(server)
                guard serverIP.prefix == (serverIP.isIPv6 ? 128 : 32), (1...65535).contains(port) else { throw ProxyTunnelError(message: "请输入 DNS 服务器 IP 与有效的目标端口。") }
                let route = try routeTo(serverIP.address)
                result.append(.init(title: "公司 DNS 路由", succeeded: true, detail: route))
                let query = try dnsQuery(domain)
                let response = try tcp(server: serverIP.address, port: 53, request: query)
                result.append(.init(title: "公司 DNS TCP/53", succeeded: true, detail: "已通过指定公司 DNS 收到响应；未使用公网回退。"))
                let addresses = try dnsAnswers(response, identifier: Array(query.dropFirst(2).prefix(2)))
                guard !addresses.isEmpty else { throw ProxyTunnelError(message: "公司 DNS 未返回 IPv4 地址。") }
                result.append(.init(title: "公司域名解析", succeeded: true, detail: addresses.joined(separator: "、")))
                let target = addresses[0]
                result.append(.init(title: "目标路由", succeeded: true, detail: try routeTo(target)))
                _ = try tcp(server: target, port: port, request: nil)
                result.append(.init(title: "目标服务 TCP/\(port)", succeeded: true, detail: "TCP 连接成功；不代表应用登录或 TLS 认证通过。"))
            } catch { result.append(.init(title: "检测未完成", succeeded: false, detail: error.localizedDescription)) }
            return result
        }.value
    }
    static func routeTo(_ ip: String) throws -> String {
        let address = try ProxyCIDR(ip)
        let output = try ProxyNetworkCommand.run("/sbin/route", ["-n", "get", address.isIPv6 ? "-inet6" : "-inet", address.address])
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("interface:") || $0.hasPrefix("gateway:") }
        guard !lines.isEmpty else { throw ProxyTunnelError(message: "未找到目标路由。") }
        return lines.joined(separator: " · ") + "（接口名不能单独证明属于 OpenVPN）"
    }
    static func dnsQuery(_ domain: String) throws -> Data {
        let labels = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".")
        guard !labels.isEmpty, domain.utf8.count <= 253, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }) else { throw ProxyTunnelError(message: "请输入有效的 ASCII 公司域名。") }
        let id = UInt16.random(in: 0...UInt16.max)
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in labels { bytes.append(UInt8(label.utf8.count)); bytes += label.utf8 }
        bytes += [0, 0, 1, 0, 1]
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes)
    }
    static func dnsAnswers(_ data: Data, identifier: [UInt8]) throws -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes.prefix(2)) == identifier, bytes[2] & 0x80 != 0 else { throw ProxyTunnelError(message: "DNS 响应格式或请求编号不匹配。") }
        let code = bytes[3] & 15
        guard code == 0 else { throw ProxyTunnelError(message: code == 3 ? "公司 DNS 返回 NXDOMAIN（域名不存在）。" : "公司 DNS 返回错误码 \(code)。") }
        func word(_ i: Int) -> Int { Int(bytes[i]) * 256 + Int(bytes[i + 1]) }
        var position = 12
        func skipName() throws {
            var labels = 0
            while position < bytes.count {
                let length = Int(bytes[position]); position += 1
                if length == 0 { return }
                if length & 0xc0 == 0xc0 { guard position < bytes.count else { break }; position += 1; return }
                guard length <= 63, position + length <= bytes.count, labels < 128 else { break }
                position += length; labels += 1
            }
            throw ProxyTunnelError(message: "DNS 响应名称被截断。")
        }
        for _ in 0..<word(4) { try skipName(); guard position + 4 <= bytes.count else { throw ProxyTunnelError(message: "DNS 问题段被截断。") }; position += 4 }
        var addresses: [String] = []
        for _ in 0..<word(6) {
            try skipName()
            guard position + 10 <= bytes.count else { throw ProxyTunnelError(message: "DNS 答案段被截断。") }
            let type = word(position), length = word(position + 8); position += 10
            guard position + length <= bytes.count else { throw ProxyTunnelError(message: "DNS 数据被截断。") }
            if type == 1 && length == 4 { addresses.append(bytes[position..<(position + 4)].map(String.init).joined(separator: ".")) }
            position += length
        }
        return addresses
    }
    private static func tcp(server: String, port: Int, request: Data?) throws -> Data {
        let ip = try ProxyCIDR(server), family = ip.isIPv6 ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyTunnelError(message: "无法创建检测连接。") }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK); _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let deadline = Date().addingTimeInterval(4)
        func wait(_ event: Int16) throws {
            var item = pollfd(fd: fd, events: event, revents: 0)
            let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
            guard remaining > 0, poll(&item, 1, remaining) > 0 else { throw ProxyTunnelError(message: "TCP/\(port) 超时；请检查 VPN、路由或服务状态。") }
        }
        let connected: Int32
        if ip.isIPv6 {
            var addr = sockaddr_in6(); addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); addr.sin6_family = UInt8(AF_INET6); addr.sin6_port = UInt16(port).bigEndian
            _ = inet_pton(AF_INET6, server, &addr.sin6_addr)
            connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = UInt8(AF_INET); addr.sin_port = UInt16(port).bigEndian
            _ = inet_pton(AF_INET, server, &addr.sin_addr)
            connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        if connected != 0 { guard errno == EINPROGRESS else { throw ProxyTunnelError(message: "TCP/\(port) 连接失败。") }; try wait(Int16(POLLOUT)) }
        var failure: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else { throw ProxyTunnelError(message: "TCP/\(port) 被拒绝或不可达（\(failure)）。") }
        guard let request else { return Data() }
        var sent = 0
        while sent < request.count {
            try wait(Int16(POLLOUT))
            let count = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: sent), request.count - sent, 0) }
            if count < 0 && errno == EAGAIN { continue }
            guard count > 0 else { throw ProxyTunnelError(message: "DNS 请求发送失败。") }; sent += count
        }
        func receive(_ length: Int) throws -> Data {
            var data = Data()
            while data.count < length {
                try wait(Int16(POLLIN)); var buffer = [UInt8](repeating: 0, count: min(length - data.count, 4096))
                let count = recv(fd, &buffer, buffer.count, 0)
                if count < 0 && errno == EAGAIN { continue }
                guard count > 0 else { throw ProxyTunnelError(message: "公司 DNS 连接提前关闭。") }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
        let header = [UInt8](try receive(2)), length = Int(header[0]) * 256 + Int(header[1])
        guard length >= 12 else { throw ProxyTunnelError(message: "DNS TCP 帧无效。") }
        return try receive(length)
    }
}
