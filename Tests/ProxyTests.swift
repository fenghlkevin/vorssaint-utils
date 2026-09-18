// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProxyYAML

final class MemoryNetwork: ProxyNetworkStore {
    var active = "wifi"
    var values: [String: [String: Any]] = ["wifi": ["HTTPEnable": 0, "ExceptionsList": ["*.local"]], "ethernet": [:]]
    var fail = false
    func activeService() throws -> String? { active }
    func read(_ service: String) throws -> [String: Any] { values[service] ?? [:] }
    func write(_ service: String, _ value: [String: Any], expected: [String: Any]) throws {
        if fail { throw ProxyNetworkError(message: "simulated authorization failure") }
        values[service] = value
    }
}
@main struct ProxyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
    static func main() async throws {
        // Exercise the Objective-C boundary directly: Swift try? cannot catch C assertions.
        for data in [Data(), Data("".utf8), Data("   \n\t".utf8), Data("# comment only\n".utf8)] {
            var parseError: NSError?
            check(VPYAMLToJSON(data, &parseError) == nil && parseError != nil, "empty YAML must return an error")
            do { _ = try ProxyConfigCompiler.document(data); fatalError("empty document accepted") } catch {}
        }

        let fixture = """
        mixed-port: 7890
        proxies:
          - {name: node, type: ss, server: example.invalid, port: 443, cipher: aes-256-gcm, password: fixture}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [node, DIRECT]}
        dns:
          enable: true
          nameserver-policy: {'*.hlkj.com': 'tcp://172.27.199.177:53'}
        rules:
          - DOMAIN,git-d.hlkj.com,DIRECT
          - DOMAIN,example.com,PROXY
          - MATCH,DIRECT
        """
        let inspected = try ProxyConfigCompiler.inspect(Data(fixture.utf8))
        check(!inspected.hasErrors, "valid fixture")
        check(inspected.issues.contains { $0.severity == .repair }, "case repair must be explicit")
        do { _ = try ProxyConfigCompiler.compile(inspected, preferences: .init(), secret: "test"); fatalError("unaccepted repair") } catch {}
        var preferences = ProxyPreferences(); preferences.repairReferences = true
        let output = try ProxyConfigCompiler.compile(inspected, preferences: preferences, secret: "test")
        let root = try JSONSerialization.jsonObject(with: output) as! [String: Any]
        check((root["rules"] as! [String])[1] == "DOMAIN,example.com,Proxy", "repair")
        check((root["dns"] as! [String: Any])["nameserver-policy"] != nil, "company DNS preserved")
        check(root["find-process-mode"] as? String == "always", "local process lookup always enabled")
        check(root["external-controller"] as? String == "127.0.0.1:19090", "controller bound locally")
        for invalid in ["rules: []\nrules: []", "rules: &a []\nproxies: *a", "---\nrules: []\n---\nrules: []"] {
            do { _ = try ProxyConfigCompiler.inspect(Data(invalid.utf8)); fatalError("unsafe YAML accepted") } catch {}
        }
        let cycle = fixture.replacingOccurrences(of: "proxies: [node, DIRECT]", with: "proxies: [Proxy]")
        let cycleResult = try ProxyConfigCompiler.inspect(Data(cycle.utf8))
        check(cycleResult.hasErrors, "cycles rejected")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = MemoryNetwork(); let journal = directory.appendingPathComponent("journal.plist")
        let lease = try ProxySystemLease(store: backend, journal: journal)
        try lease.enable(port: 17890)
        check(backend.values["wifi"]?["HTTPPort"] as? Int == 17890, "enabled")
        backend.values["wifi"]?["HTTPProxy"] = "another-client"
        backend.values["wifi"]?["Unowned"] = 42
        try ProxySystemLease(store: backend, journal: journal).restore()
        check(backend.values["wifi"]?["HTTPProxy"] as? String == "another-client", "foreign change preserved")
        check(backend.values["wifi"]?["HTTPEnable"] as? Int == 1, "foreign protocol retained")
        check(backend.values["wifi"]?["Unowned"] as? Int == 42, "unowned field preserved")
        backend.values["wifi"]?["HTTPEnable"] = 0
        let fresh = try ProxySystemLease(store: backend, journal: journal)
        try fresh.enable(port: 17890); backend.active = "ethernet"; try fresh.enable(port: 17890)
        check(backend.values["wifi"]?["HTTPEnable"] as? Int == 0, "old interface restored")
        try fresh.restore()
        try fresh.enable(port: 17890)
        backend.fail = true
        do { try fresh.restore(); fatalError("restore failure ignored") } catch {}
        check(!fresh.records.isEmpty, "failed restore retains journal")
        backend.fail = false
        try ProxySystemLease(store: backend, journal: journal).restore()
        backend.fail = true
        do { try ProxySystemLease(store: backend, journal: journal).enable(port: 17890); fatalError("write failure ignored") } catch {}
        backend.fail = false; try fresh.restore()
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let actual = try ProxyConfigCompiler.inspect(data)
            check(!actual.hasErrors, "user config compatibility")
            print("User configuration: \(actual.nodeNames.count) nodes, \(actual.groups.count) groups, \(actual.ruleCount) rules; compatible")
        }
        let sessionNetwork = MemoryNetwork()
        let sessionURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        let sessionLease = try ProxySystemLease(store: sessionNetwork, journal: sessionURL)
        let session = try ProxySystemSession(lease: sessionLease)
        let owner = UUID(), stranger = UUID()
        try session.set(true, port: 7890, owner: owner, now: 1)
        check(session.active, "helper enables proxy")
        do { try session.set(false, port: 0, owner: stranger, now: 2); fatalError("foreign session accepted") } catch {}
        try session.stop(stranger)
        check(session.active, "foreign disconnect does not restore owner")
        sessionNetwork.active = "ethernet"
        session.tick(now: 3)
        check(sessionLease.ownedService == "ethernet", "helper migrates physical service")
        try session.heartbeat(owner, now: 10)
        session.tick(now: 24)
        check(session.active, "heartbeat extends lease")
        session.tick(now: 26)
        check(!session.active && sessionNetwork.values["ethernet"]?["HTTPProxy"] == nil, "expired heartbeat restores")
        try session.set(true, port: 7890, owner: owner, now: 30)
        sessionNetwork.fail = true
        do { try session.stop(owner); fatalError("restore failure ignored") } catch {}
        sessionNetwork.fail = false
        session.tick(now: 31)
        check(!session.active, "failed stop retries restoration instead of re-enabling")
        try session.set(true, port: 7890, owner: owner, now: 40)
        sessionNetwork.values["ethernet"]?["HTTPProxy"] = "foreign.invalid"
        session.tick(now: 41)
        check(!session.active && sessionNetwork.values["ethernet"]?["HTTPProxy"] as? String == "foreign.invalid", "foreign changes preserved")
        do { try session.set(true, port: 80, owner: owner, now: 50); fatalError("privileged port accepted") } catch {}
        print("Proxy compiler, system restoration and authenticated helper lease tests passed")
    }
}
