// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine

struct NetworkChainProcess {
    let id: String
    let name: String
    let path: String?
}

@MainActor final class NetworkChainService: ObservableObject {
    @Published private(set) var sockets: [NetworkChainSocket] = []
    @Published private(set) var processes: [Int32: NetworkChainProcess] = [:]
    @Published private(set) var sampledAt: Date?
    @Published private(set) var issue: String?
    @Published private(set) var loading = false
    @Published private(set) var flows: [String: NetworkFlowCounter] = [:]
    @Published private(set) var flowIssue: String?
    private var rateTracker = NetworkFlowRateTracker()
    private var timer: Timer?
    private var generation = 0
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        ProxyService.shared.telemetry.setVisible("network-chain", true)
    }
    func stop() {
        generation += 1; loading = false; flows = [:]; rateTracker.reset()
        timer?.invalidate(); timer = nil
        ProxyService.shared.telemetry.setVisible("network-chain", false)
    }
    func refresh() {
        guard !loading else { return }
        loading = true
        let token = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = BoundedProcessRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-FpcfPnT"], timeout: 4, maxOutputBytes: 4 * 1024 * 1024)
            let output = String(decoding: result.output, as: UTF8.self)
            let valid = !result.timedOut && result.output.count < 4 * 1024 * 1024
                && (result.status == 0 || (result.status == 1 && output.isEmpty)) && !output.contains("lsof:")
            let rows = valid ? NetworkChainSupport.parse(output) : []
            // One finite cumulative section: no live child, PTY buffering or
            // process totals. Join each flow by pid + exact endpoint pair.
            let flowResult = BoundedProcessRunner.run("/usr/bin/nettop", ["-n", "-x", "-J", "bytes_in,bytes_out", "-L", "1"], timeout: 3, maxOutputBytes: 4 * 1024 * 1024)
            let flowText = String(decoding: flowResult.output, as: UTF8.self)
            let flowValid = !flowResult.timedOut && flowResult.status == 0 && flowResult.output.count < 4 * 1024 * 1024 && flowText.contains("time,,bytes_in,bytes_out")
            let counters = flowValid ? NetworkFlowSupport.parse(flowText) : [:]
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.loading = false
                guard valid else {
                    self.issue = "连接扫描失败或权限不足，请重试。"; self.sockets = []; self.processes = [:]; self.sampledAt = nil; self.flows = [:]; self.rateTracker.reset()
                    return
                }
                var identities: [Int32: NetworkChainProcess] = [:]
                for row in rows where identities[row.pid] == nil {
                    let app = ResponsibleProcess.regularAppOwner(of: row.pid)
                        ?? NSRunningApplication(processIdentifier: ResponsibleProcess.owner(of: row.pid))
                    let path = app?.bundleURL?.path
                    var name = app?.localizedName ?? row.process
                    if let path, path.hasSuffix("/ChatGPT.app"),
                       FileManager.default.fileExists(atPath: path + "/Contents/Resources/codex-cli") { name = "ChatGPT / Codex" }
                    identities[row.pid] = .init(id: path.map { "app:" + $0 } ?? "process:" + row.process, name: name, path: path)
                }
                if flowValid {
                    self.flows = self.rateTracker.sample(counters, now: ProcessInfo.processInfo.systemUptime)
                    self.flowIssue = nil
                } else {
                    self.flows = [:]; self.rateTracker.reset()
                    self.flowIssue = "连接流量采集失败，显示未采集，不以软件总量代替。"
                }
                self.processes = identities; self.sockets = rows; self.sampledAt = Date(); self.issue = nil
            }
        }
    }
}
