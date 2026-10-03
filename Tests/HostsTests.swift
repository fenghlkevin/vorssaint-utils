// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main enum HostsTests {
    static func main() throws {
        var count = 0
        func check(_ ok: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try ok() else { fatalError(name) }; count += 1
        }
        func rejected(_ name: String, _ body: () throws -> Void) {
            do { try body(); fatalError("Expected rejection: " + name) } catch { count += 1 }
        }
        let legacy = try JSONDecoder().decode(ProxyTunnelReply.self, from: Data(#"{"success":true,"active":false,"systemProxy":false,"routeCount":0,"message":""}"#.utf8))
        try check(legacy.helperCodeHash == nil && legacy.systemProxy == false, "Legacy helper status remains decodable")
        let modern = ProxyTunnelReply(helperCodeHash: "current", systemProxy: false)
        try check(JSONDecoder().decode(ProxyTunnelReply.self, from: modern.encoded).helperCodeHash == "current", "Helper identity survives XPC serialization")
        let pending = [HostsProfile(name: "待应用", content: "127.0.0.1 app.test", enabled: true)]
        try check(HostsHelperPolicy.canDisable(hasSnapshot: true, busy: false, storageFailure: false, managedContent: "", profiles: pending), "Pending-only profiles can be disabled")
        try check(!HostsHelperPolicy.canDisable(hasSnapshot: true, busy: true, storageFailure: false, managedContent: "", profiles: pending), "Busy operation blocks disable")
        try check(!HostsHelperPolicy.canDisable(hasSnapshot: false, busy: false, storageFailure: false, managedContent: "owned", profiles: []), "Unknown snapshot blocks system disable")
        try check(!HostsHelperPolicy.canDisable(hasSnapshot: true, busy: false, storageFailure: true, managedContent: "owned", profiles: []), "Storage failure blocks disable")
        let disabled = HostsHelperPolicy.disabledProfiles(pending)
        try check(disabled.count == pending.count && disabled[0].id == pending[0].id && disabled[0].content == pending[0].content && !disabled[0].enabled, "Disable retains profile library")
        try check(!HostsHelperPolicy.canDisable(hasSnapshot: true, busy: false, storageFailure: false, managedContent: "", profiles: disabled), "Already-disabled has no action")
        try check(HostsHelperPolicy.needsReplacement(expectedHash: "new", runningHash: nil), "Legacy helper lacks Hosts handshake")
        try check(HostsHelperPolicy.needsReplacement(expectedHash: "new", runningHash: "old"), "Stale signed helper needs renewal")
        try check(!HostsHelperPolicy.needsReplacement(expectedHash: "new", runningHash: "new"), "Matching helper does not renew")
        rejected("Unknown embedded signing hash") { _ = try HostsHelperPolicy.needsReplacement(expectedHash: nil, runningHash: nil) }
        try check(HostsHelperPolicy.canReplace(systemProxy: false, tunnelActive: false, tunnelInterface: nil), "Idle helper may be renewed")
        try check(!HostsHelperPolicy.canReplace(systemProxy: true, tunnelActive: false, tunnelInterface: nil), "Active system proxy prevents renewal")
        try check(!HostsHelperPolicy.canReplace(systemProxy: false, tunnelActive: true, tunnelInterface: "utun8"), "Active TUN prevents renewal")
        try check(!HostsHelperPolicy.canReplace(systemProxy: false, tunnelActive: false, tunnelInterface: "utun8"), "Prepared TUN prevents renewal")
        try check(!HostsHelperPolicy.canReplace(systemProxy: nil, tunnelActive: false, tunnelInterface: nil), "Unknown system lease prevents renewal")
        try check(!HostsHelperPolicy.canReplace(systemProxy: false, tunnelActive: nil, tunnelInterface: nil), "Unknown tunnel lease prevents renewal")
        for base in ["", "127.0.0.1 localhost", "127.0.0.1 localhost\n", "# 原有记录\r\n127.0.0.1 localhost\r\n"] {
            let composed = try HostsSupport.compose(current: base, managed: "10.0.0.1 dev.test\n")
            try check(HostsSupport.split(composed).base == base, "Preserve original bytes")
            try check(HostsSupport.compose(current: composed, managed: "") == base, "Disable restores original")
            try check(HostsSupport.compose(current: composed, managed: "10.0.0.1 dev.test\n") == composed, "Idempotent")
        }
        try check(HostsSupport.issues("# comment\n127.0.0.1 app.test alias.test # comment\n::1 app.test").isEmpty, "IPv4, IPv6, aliases")
        try check(!HostsSupport.issues("999.1.1.1 app.test").isEmpty, "Bad IP")
        try check(!HostsSupport.issues("127.0.0.1").isEmpty, "Missing name")
        try check(!HostsSupport.issues("127.0.0.1 https://example.com").isEmpty, "Reject URL")
        try check(!HostsSupport.issues("127.0.0.1 a..test").isEmpty, "Bad labels")
        try check(!HostsSupport.issues("127.0.0.1 -bad.test").isEmpty, "Bad hyphen")
        try check(!HostsSupport.issues("127.0.0.1 APP.test\n10.0.0.1 app.test.").isEmpty, "Case-folded domain conflict")
        try check(!HostsSupport.issues("10.0.0.1 app.test", base: "127.0.0.1 app.test").isEmpty, "External conflict")
        try check(HostsSupport.issues("10.0.0.1 app.test", base: "::1 app.test").isEmpty, "Separate families")
        try check(HostsSupport.issues("127.0.0.1 app.test\n127.0.0.1 app.test").isEmpty, "Same address duplicate")
        rejected("Duplicate marker") { _ = try HostsSupport.split("\n" + HostsSupport.begin + "\n" + HostsSupport.begin + "\n" + HostsSupport.end + "\n") }
        rejected("Missing marker") { _ = try HostsSupport.split("\n" + HostsSupport.begin + "\n") }
        rejected("Embedded marker") { _ = try HostsSupport.compose(current: "", managed: HostsSupport.begin) }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hosts-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("hosts")
        let backup = folder.appendingPathComponent("backups").path
        let original = "127.0.0.1 localhost\n# kept\n"
        try Data(original.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let request = HostsWriteRequest(expected: original, managedContent: "10.0.0.1 app.test\n")
        let output = try HostsSystemWriter.apply(request, path: target.path, backupDirectory: backup, owner: getuid())
        try check(String(contentsOf: target, encoding: .utf8) == output, "Atomic file write")
        try check(String(contentsOfFile: backup + "/previous.hosts", encoding: .utf8) == original, "Backup before write")
        try check((FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o644, "Preserve permissions")
        rejected("Stale content") { _ = try HostsSystemWriter.apply(request, path: target.path, backupDirectory: backup, owner: getuid()) }
        try check(String(contentsOf: target, encoding: .utf8) == output, "Stale rejection preserves file")
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        rejected("Symlink") { _ = try HostsSystemWriter.apply(request, path: link.path, backupDirectory: backup, owner: getuid()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: target.path)
        rejected("Writable by others") { _ = try HostsSystemWriter.apply(.init(expected: output, managedContent: ""), path: target.path, backupDirectory: backup, owner: getuid()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let removed = try HostsSystemWriter.apply(.init(expected: output, managedContent: ""), path: target.path, backupDirectory: backup, owner: getuid())
        try check(removed == original, "Writer disable preserves base")
        print("Hosts: \(count) checks passed; system /etc/hosts untouched")
    }
}
