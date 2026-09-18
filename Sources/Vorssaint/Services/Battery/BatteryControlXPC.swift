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

    /// Inspect the RUNNING image, not the file that an installer may have replaced.
    /// nil is unknown (permissions, exited PID or invalid code), never a mismatch.
    static func runningPeerMatchesSigner(pid: Int32) -> Bool? {
        guard pid > 1 else { return nil }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary,
                                            [], &guest) == errSecSuccess, let guest else { return nil }
        var identity: SecRequirement?
        guard SecRequirementCreateWithString("identifier \"\(helperID)\"" as CFString, [], &identity) == errSecSuccess,
              SecCodeCheckValidity(guest, [], identity) == errSecSuccess,
              let text = requirement(for: helperID) else { return nil }
        var pinned: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &pinned) == errSecSuccess else { return nil }
        let result = SecCodeCheckValidity(guest, [], pinned)
        if result == errSecSuccess { return true }
        return result == errSecCSReqFailed ? false : nil
    }

    static func embeddedHelperMatchesSigner() -> Bool {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(helperID)")
        var code: SecStaticCode?
        var req: SecRequirement?
        guard let text = requirement(for: helperID),
              SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
    }

    // Capture the running image once, before an installer can replace its file.
    static let runningCodeHash: String? = {
        var code: SecCode?
        var image: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &image) == errSecSuccess, let image else { return nil }
        return codeHash(image)
    }()

    static func embeddedCodeHash() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(helperID)")
        var image: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &image) == errSecSuccess,
              let image, SecStaticCodeCheckValidity(image, [], nil) == errSecSuccess else { return nil }
        return codeHash(image)
    }

    private static func codeHash(_ image: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(image, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

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
    var systemChargeLimitBackend: Bool?
    var systemChargeLimits: [Int]?
    var systemLimitReadback: Int?
    var systemPolicyLimit: Int?
    var interfaceDiagnostics: String?
    var interfaceUnavailable: Bool?
    var version = 2
    var codeHash: String?
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
