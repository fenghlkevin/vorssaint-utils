// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct ProxyActivityTests {
    @MainActor static func main() async throws {
        let pathOnly = ProxyConnection.parse(["id": "path", "metadata": ["processPath": "/Applications/Example.app/Contents/MacOS/Example"]])!
        precondition(pathOnly.process == "Example")
        let remote = ProxyConnection.parse(["id": "lan", "metadata": ["sourceIP": "192.0.2.9"]])!
        precondition(remote.process == "客户端 · 192.0.2.9")
        var sampler = ProxyTrafficSampler()
        func snapshot(_ up: Double, _ down: Double) -> [String: Any] {
            ["uploadTotal": up, "downloadTotal": down, "connections": [["id": "one", "upload": up, "download": down, "metadata": ["process": "Fixture", "processPath": "/fixture", "host": "example.invalid", "destinationPort": "443"]]]]
        }
        let first = sampler.sample(snapshot(100, 200), now: 1)
        precondition(first.up == 0 && first.clients.count == 1)
        let next = sampler.sample(snapshot(300, 600), now: 3)
        precondition(next.up == 100 && next.down == 200 && next.clients[0].downloadRate == 200)
        let reset = sampler.sample(snapshot(0, 0), now: 4)
        precondition(reset.up == 0 && reset.down == 0)
        let gap = sampler.sample(snapshot(100000, 100000), now: 50)
        precondition(gap.up == 0 && gap.clients[0].uploadRate == 0)
        let redact = ProxyLogRedactor(source: ["proxies": [["password": "fixture-password", "uuid": "fixture-uuid"]]], controllerSecret: "fixture-token")
        let result = redact.redact("fixture-password fixture-uuid Authorization=fixture-token https://user:pass@example.invalid/?token=private Bearer private")
        for secret in ["fixture-password", "fixture-uuid", "fixture-token", "private", "user:pass"] { precondition(!result.contains(secret)) }
        let boundary = redact.redact(String(repeating: "x", count: 8185) + "fixture-password")
        precondition(!boundary.contains("fixture"), "credential truncation boundary leaked")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let telemetry = ProxyTelemetry(root: root)
        for index in 0..<2200 { telemetry.addLog(level: "warning", message: String(repeating: index % 2 == 0 ? "网" : "x", count: 8192)) }
        precondition(telemetry.logs.count == 1000)
        for _ in 0..<100 { telemetry.ingest(snapshot(100, 200)) }
        precondition(telemetry.history.count == 60)
        await telemetry.finishArchive()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Logs"), includingPropertiesForKeys: [.fileSizeKey])
        precondition(files.count <= 2)
        for file in files { let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!; precondition(size <= 512 * 1024) }
        telemetry.clearLogs(); await telemetry.finishArchive()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Logs").path)
        precondition(remaining.isEmpty && telemetry.logs.isEmpty)
        print("Traffic deltas, reset/gap handling, credential redaction, bounded history/logs and archive rotation passed")
    }
}
