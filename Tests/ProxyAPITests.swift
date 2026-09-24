// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
final class ProxyStubProtocol: URLProtocol {
    static var observed: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.observed = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class DelayBatchProbe {
    var started: [String] = []
    var completed: [String] = []
    var active = 0
    var maximum = 0
    func start(_ name: String) { started.append(name); active += 1; maximum = max(maximum, active) }
    func finish(_ name: String) { completed.append(name); active -= 1 }
}
@main struct ProxyAPITests {
    @MainActor static func main() async throws {
        let api = ProxyAPI(port: 29090, secret: "fixture-token", protocolClasses: [ProxyStubProtocol.self])
        _ = try await api.request(["proxies", "HK / #1?中"], method: "PUT", body: ["name": "DIRECT"])
        guard let request = ProxyStubProtocol.observed,
              request.url?.absoluteString == "http://127.0.0.1:29090/proxies/HK%20%2F%20%231%3F%E4%B8%AD",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
              request.httpMethod == "PUT" else { fatalError("API segment encoding/auth regression") }
        print("Proxy API path encoding and authentication passed")
        let probe = DelayBatchProbe()
        await ProxyDelayBatch.run(["slow", "b", "c", "d", "e", "f"], operation: { name in
            try? await Task.sleep(nanoseconds: name == "slow" ? 200_000_000 : 10_000_000)
            return name == "c" ? -1 : 123
        }, started: { probe.start($0) }, completed: { name, delay, _ in
            precondition(delay == (name == "c" ? -1 : 123), "result must belong to correct node")
            probe.finish(name)
        })
        precondition(probe.maximum == 3 && probe.active == 0, "bounded concurrency")
        precondition(probe.started.count == 6 && Set(probe.completed).count == 6, "each node completes once")
        precondition(probe.completed.firstIndex(of: "d")! < probe.completed.firstIndex(of: "slow")!, "slow node must not block next queued node")
        let cancelled = DelayBatchProbe()
        let task = Task {
            await ProxyDelayBatch.run(["a", "b", "c", "d", "e"], operation: { _ in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return 100
            }, started: { cancelled.start($0) }, completed: { name, _, _ in cancelled.finish(name) })
        }
        while cancelled.started.count < 3 { await Task.yield() }
        task.cancel(); await task.value
        precondition(cancelled.started.count == 3 && cancelled.completed.isEmpty, "cancel must stop queue and suppress stale results")
        print("Delay batch rolling concurrency, result identity, failures and cancellation passed")
    }
}
