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
}
struct ProxyGuardianEvent: Codable {
    var identifier: String
    var success: Bool
    var message: String
    var corePID: Int32? = nil
    var systemProxy: Bool = false
}

enum ProxyGuardianSocket {
    static func path(root: URL) -> String {
        let hash = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "/private/tmp/vorssaint-tun-\(getuid())-\(hash).sock"
    }
}
