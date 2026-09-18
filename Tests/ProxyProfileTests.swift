// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct ProxyProfileTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxyProfileStore(root: root)
        let original = Data("# preserved comment\nproxies: []\nproxy-groups: []\nrules: ['MATCH,DIRECT']\ndns: {enable: true, nameserver: [1.1.1.1]}\n".utf8)
        let profile = try store.importProfile(data: original, name: "fixture.yaml")
        let draft = ProxyDraft(yaml: String(decoding: original, as: UTF8.self), overrides: "dns: {nameserver: [8.8.8.8]}")
        let effective = try ProxyConfigCompiler.document(draft.effective())
        precondition((effective["dns"] as? [String: Any])?["enable"] as? Bool == true)
        precondition((effective["dns"] as? [String: Any])?["nameserver"] as? [String] == ["8.8.8.8"])
        try store.saveDraft(.init(yaml: "invalid: ["), for: profile.id)
        let checked1 = try store.draft(profile.id).yaml == "invalid: ["
        precondition(checked1)
        let checked2 = try Data(contentsOf: store.original(profile.id)) == original
        precondition(checked2)
        try store.commit(.init(note: "good", draft: draft), for: profile.id, healthy: true)
        let good = try store.committed(profile.id)
        try store.beginApply(previous: profile.id, target: profile.id)
        try store.commit(.init(note: "interrupted", draft: .init(yaml: "rules: []")), for: profile.id, healthy: true)
        try store.recoverApply()
        let checked3 = try store.committed(profile.id) == good
        precondition(checked3)
        let duplicate = try store.duplicate(profile.id)
        let checked4 = try store.committed(duplicate.id) == good
        precondition(checked4)
        do { _ = try ProxyDraft(yaml: draft.yaml, overrides: "external-controller: 0.0.0.0:9999").effective(); fatalError("managed override accepted") } catch {}
        let oldPreferences = Data(#"{"mixedPort":7890,"controllerPort":19090,"allowLAN":false,"systemProxy":false,"autoStart":false,"mode":"rule","repairReferences":false,"dnsPort":1053,"selections":{}}"#.utf8)
        let migrated = try JSONDecoder().decode(ProxyPreferences.self, from: oldPreferences)
        precondition(!migrated.tunnelSettings.enabled)
        let a = ProxyConfigCompiler.providerPath("a", ["url": "https://example.test/a", "behavior": "domain"])
        let b = ProxyConfigCompiler.providerPath("a", ["url": "https://example.test/b", "behavior": "domain"])
        precondition(a != b)
        print("Profile originals, invalid drafts, overrides, crash transaction recovery, history and preference migration passed")
    }
}
