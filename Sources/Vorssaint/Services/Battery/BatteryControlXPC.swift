// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security
import CryptoKit

enum BatteryControlIdentifiers {
    #if VORSSAINT_DEVELOPMENT
    static let appID = "com.vorssaint.utils.dev"
    #else
    static let appID = "com.vorssaint.utils"
    #endif
    static let helperID = appID + ".battery-control"
    static let plistName = helperID + ".plist"

    /// Pin the peer to our own signing certificate AND its exact identifier.
    /// Works with the existing development certificate without accepting ad-hoc peers.
    static func requirement(for identifier: String) -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
    }
}

@objc protocol BatteryControlXPCProtocol {
    func update(_ data: Data, withReply reply: @escaping (Data) -> Void)
    func command(_ name: String, withReply reply: @escaping (Data) -> Void)
    func status(withReply reply: @escaping (Data) -> Void)
    func restore(withReply reply: @escaping (Data) -> Void)
    func prepareForRemoval(withReply reply: @escaping (Data) -> Void)
}

struct BatteryControlResponse: Codable {
    var version = 2
    var backendName: String?
    var dischargeSupported: Bool?
    var needsTakeover: Bool?
    var supported = false
    var ledSupported = false
    var active = false
    var command = BatteryCommand.automatic
    var override = BatteryCommand.automatic
    var overheated = false
    var error: String?
    var warning: String?
    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
