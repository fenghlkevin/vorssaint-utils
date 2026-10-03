// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum HostsHelperPolicy {
    /// Missing legacy hash means old protocol. Unknown lease state never permits
    /// replacement: this daemon is shared with system proxy and TUN sessions.
    static func needsReplacement(expectedHash: String?, runningHash: String?) throws -> Bool {
        guard let expectedHash, !expectedHash.isEmpty else { throw HostsFailure(message: "无法验证应用内网络助手的签名。") }
        return runningHash != expectedHash
    }
    static func canReplace(systemProxy: Bool?, tunnelActive: Bool?, tunnelInterface: String?) -> Bool {
        systemProxy == false && tunnelActive == false && tunnelInterface == nil
    }
    static func canDisable(hasSnapshot: Bool, busy: Bool, storageFailure: Bool,
                           managedContent: String, profiles: [HostsProfile]) -> Bool {
        hasSnapshot && !busy && !storageFailure && (!managedContent.isEmpty || profiles.contains(where: \.enabled))
    }
    static func disabledProfiles(_ profiles: [HostsProfile]) -> [HostsProfile] {
        profiles.map { var item = $0; item.enabled = false; return item }
    }
}
