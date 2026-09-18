// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import CryptoKit

struct ProxyTunnelReply: Codable {
    var success = true
    var active = false
    var systemProxy: Bool?
    var interface: String?
    var routeCount = 0
    var address4: String?
    var address6: String?
    var message = ""
    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
@objc protocol ProxyTunnelXPCProtocol {
    func systemProxy(_ enabled: Bool, port: Int, withReply reply: @escaping (Data) -> Void)
    func systemHeartbeat(withReply reply: @escaping (Data) -> Void)
    func prepare(_ plan: Data, withReply reply: @escaping (FileHandle?, Data) -> Void)
    func activate(withReply reply: @escaping (Data) -> Void)
    func heartbeat(withReply reply: @escaping (Data) -> Void)
    func stop(withReply reply: @escaping (Data) -> Void)
}
enum ProxyTunnelIdentifiers {
    #if VORSSAINT_DEVELOPMENT
    static let appID = "com.vorssaint.utils.dev"
    #else
    static let appID = "com.vorssaint.utils"
    #endif
    static let helperID = appID + ".proxy-tun"
    static let plistName = helperID + ".plist"
    static func requirement(for identifier: String) -> String? {
        var code: SecCode?, image: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &image) == errSecSuccess, let image,
              SecCodeCopySigningInformation(image, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else { return nil }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
    }
    static func interface() -> NSXPCInterface { NSXPCInterface(with: ProxyTunnelXPCProtocol.self) }
}
