// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
@MainActor final class ProxyWindowController {
    static let shared = ProxyWindowController()
    func show(page: Int = 0) {}
}
enum LaunchAtLogin {
    static var isEnabled: Bool { false }
    static func setEnabled(_ value: Bool) throws {}
}
enum NetworkInfoLocalAddresses {
    struct Address: Identifiable { var id: String { ip }; let ip: String; let interface: String; let isTunnel: Bool }
    static func read() throws -> [Address] { [] }
}
@main struct ProxyUIFixture {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let telemetry = ProxyTelemetry(root: root)
        let rows: [[String: Any]] = (0..<8).map { index in
            ["id": "connection-\(index)", "metadata": ["process": index % 2 == 0 ? "Safari" : "Terminal", "host": "fixture-\(index).invalid", "destinationIP": "192.0.2.1", "destinationPort": "443", "network": "tcp"], "rule": "DOMAIN-SUFFIX", "chains": ["Proxy", "Fixture"], "upload": 24000, "download": 580000]
        }
        for index in 0..<15 { telemetry.ingest(["connections": rows, "uploadTotal": index * 32000, "downloadTotal": index * 850000, "memory": 42000000]) }
        telemetry.ingestMemory(["inuse": 42000000])
        telemetry.addLog(level: "info", message: "核心已就绪。")
        telemetry.addLog(level: "warning", message: "[TCP] Fixture connection to example.invalid:443 matched DOMAIN-SUFFIX using Proxy.")
        let core = URL(fileURLWithPath: CommandLine.arguments[2])
        let emptyService = ProxyService(root: root.appendingPathComponent("empty-profile"), core: core, guardian: root.appendingPathComponent("unused"))
        let draftRoot = root.appendingPathComponent("empty-draft-" + UUID().uuidString)
        let store = ProxyProfileStore(root: draftRoot)
        _ = try store.importProfile(data: Data("proxies: []\nproxy-groups: [{name: Proxy, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,DIRECT']\n".utf8), name: "fixture")
        let draftService = ProxyService(root: draftRoot, core: core, guardian: root.appendingPathComponent("unused"))
        draftService.editorYAML = ""
        let views: [(String, AnyView)] = [("panel", AnyView(ScrollView { PanelProxyView(service: draftService).frame(width: 440) })), ("delay-states", AnyView(HStack {
            ProxyDelayBadge(delay: 171, date: Date())
            ProxyDelayBadge(delay: 512)
            ProxyDelayBadge(delay: -1)
            ProxyDelayBadge(delay: nil)
            ProxyDelayBadge(delay: nil, testing: true)
            ProxyDelayBadge(delay: nil, blocked: true)
        })), ("empty-profile", AnyView(ProxyStructuredEditor(service: emptyService))), ("empty-draft", AnyView(ProxyStructuredEditor(service: draftService))), ("traffic", AnyView(ProxyTrafficView(telemetry: telemetry))), ("connections", AnyView(ProxyConnectionsView(telemetry: telemetry))), ("logs", AnyView(ProxyLogsView(telemetry: telemetry)))]
        for (name, view) in views {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: view.frame(width: 1040, height: 620).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting; window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("bitmap unavailable") }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
            try data.write(to: root.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        print("Isolated SwiftUI fixtures rendered without starting a core or changing network settings")
    }
}
