// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
struct ProxyGuardianRequest: Codable {
    var command: String
    var identifier: String = UUID().uuidString
    var corePath: String? = nil
    var workPath: String? = nil
    var configPath: String? = nil
    var mixedPort: Int? = nil
    var systemProxy: Bool? = nil
    var tunInterface: String? = nil
    var tunnelPlan: Data? = nil
    var useSystemHelper: Bool? = nil
    var profileID: UUID? = nil
}
struct ProxyGuardianEvent: Codable {
    var identifier: String
    var success: Bool
    var message: String
    var corePID: Int32? = nil
    var systemProxy: Bool = false
    var tunnel: ProxyTunnelReply? = nil
    var configPath: String? = nil
    var profileID: UUID? = nil
    var committed: Bool = false
}

enum ProxyGuardianSocket {
    static var serviceID: String {
        #if VORSSAINT_DEVELOPMENT
        return "com.vorssaint.utils.dev.proxy-agent"
        #else
        return "com.vorssaint.utils.proxy-agent"
        #endif
    }
    static func controlPath(root: URL) -> String { path(root: root).replacingOccurrences(of: "vorssaint-tun-", with: "vorssaint-agent-") }
    static func path(root: URL) -> String {
        let hash = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "/private/tmp/vorssaint-tun-\(getuid())-\(hash).sock"
    }
}

/// One bounded request/reply per connection; closing a UI connection never owns the core lifetime.
enum ProxyGuardianTransport {
    static func read(_ fd: Int32) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 262144 {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ProxyNetworkError(message: "代理后台连接中断或响应超时。") }
            data.append(contentsOf: buffer.prefix(count))
            if let end = data.firstIndex(of: 10) { return data.prefix(upTo: end) }
        }
        throw ProxyNetworkError(message: "代理后台消息超出限制。")
    }
    static func write<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value); data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProxyNetworkError(message: "无法发送代理后台请求。") }
                offset += count
            }
        }
    }
}
