// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct ProxyCoreIntegration {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let guardianURL = URL(fileURLWithPath: CommandLine.arguments[3])
        try ProxyFiles.directory(root)
        let work = root.appendingPathComponent("runtime")
        try ProxyFiles.directory(work)
        var preferences = ProxyPreferences()
        preferences.mixedPort = 27890; preferences.controllerPort = 29090; preferences.dnsPort = 21053
        preferences.systemProxy = false; preferences.allowLAN = false; preferences.repairReferences = true
        let data: Data
        if CommandLine.arguments.count > 4 { data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])) }
        else { data = Data("proxies: []\nproxy-groups: [{name: Proxy, type: select, proxies: [DIRECT, REJECT]}]\nrules: [MATCH,DIRECT]\n".replacingOccurrences(of: "[MATCH,DIRECT]", with: "['MATCH,DIRECT']").utf8) }
        let inspected = try ProxyConfigCompiler.inspect(data)
        let config = work.appendingPathComponent("runtime.yaml")
        let secret = UUID().uuidString
        try ProxyFiles.write(ProxyConfigCompiler.compile(inspected, preferences: preferences, secret: secret), to: config)
        try await ProxyResources.prepare(inspected, work: work)
        try await ProxyCore.validate(executable: executable, work: work, config: config)
        print("Core configuration validation passed")
        let guardian = ProxyGuardianClient()
        try guardian.launch(executable: guardianURL, root: root)
        do {
            _ = try await guardian.send(.init(command: "recover"))
            let started = try await guardian.send(.init(command: "start", corePath: executable.path, workPath: work.path, configPath: config.path))
            let api = ProxyAPI(port: preferences.controllerPort, secret: secret)
            try await api.ready(requiredProviders: inspected.requiredProviders, deadline: Date().addingTimeInterval(100))
            print("Core API and \(inspected.requiredProviders.count) required rule providers ready")
            let groups = try await api.groups()
            guard groups.count >= inspected.groups.count else { fatalError("missing groups") }
            _ = try await api.request(["configs"], method: "PATCH", body: ["mode": "direct"])
            let changed = try await api.request(["configs"])
            guard changed["mode"] as? String == "direct" else { fatalError("mode mismatch") }
            if let group = groups.first(where: { $0.members.contains("DIRECT") }) {
                _ = try await api.request(["proxies", group.name], method: "PUT", body: ["name": "DIRECT"])
                let read = try await api.groups()
                guard read.contains(where: { $0.name == group.name && $0.selected == "DIRECT" }) else { fatalError("selection mismatch") }
            }
            if CommandLine.arguments.count > 4 {
                for name in inspected.nodeNames {
                    do {
                        let delay = try await api.request(["proxies", name, "delay"], query: [.init(name: "timeout", value: "5000"), .init(name: "url", value: "https://www.gstatic.com/generate_204")])
                        print("Node connectivity test: \(delay["delay"] as? Int ?? -1) ms")
                    } catch { print("Node connectivity test: unavailable (configuration accepted)") }
                }
            }
            guardian.close() // Simulates UI death: EOF must stop the actual core.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if let pid = started.corePID, kill(pid, 0) == 0 { fatalError("core orphaned after UI pipe closed") }
            print("Mode, group selection, guardian EOF cleanup passed; system proxy untouched")
        } catch { _ = try? await guardian.send(.init(command: "stop")); guardian.close(); throw error }
    }
}
