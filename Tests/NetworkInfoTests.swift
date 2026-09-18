// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Darwin

private final class NetworkInfoMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status: Int
        let body: String
        if url.host == "ipv4.ddnspod.com" {
            status = 503; body = "upstream unavailable"
        } else if url.host == "myip.ipip.net" {
            status = 200; body = "当前 IP：8.8.4.4  来自于：中国 广东 深圳"
        } else if url.host == "api.ipify.org" {
            status = 200; body = "1.1.1.1"
        } else if url.path == "/8.8.4.4" {
            status = 200
            body = #"{"success":true,"ip":"8.8.4.4","country":"United States","region":"California","city":"Mountain View","connection":{"asn":15169,"org":"Google LLC","isp":"Google"}}"#
        } else {
            status = 429; body = "rate limited"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct NetworkInfoTests {
    @MainActor
    static func main() async throws {
        let active = UInt32(IFF_UP | IFF_RUNNING)
        precondition(NetworkInfoLocalAddresses.includes(interface: "en0", flags: active))
        precondition(NetworkInfoLocalAddresses.includes(interface: "bridge0", flags: active))
        precondition(!NetworkInfoLocalAddresses.includes(interface: "en0", flags: 0))
        precondition(!NetworkInfoLocalAddresses.includes(interface: "lo0", flags: active | UInt32(IFF_LOOPBACK)))
        precondition(NetworkInfoLocalAddresses.includes(interface: "ppp0", flags: active | UInt32(IFF_POINTOPOINT)))
        precondition(NetworkInfoLocalAddresses.isTunnel(interface: "tun0", flags: active))
        precondition(NetworkInfoLocalAddresses.isTunnel(interface: "tap0", flags: active))
        precondition(!NetworkInfoLocalAddresses.isTunnel(interface: "en0", flags: active))
        for name in ["awdl0", "llw0"] {
            precondition(!NetworkInfoLocalAddresses.includes(interface: name, flags: active))
        }
        for name in ["utun3", "ipsec0"] {
            precondition(NetworkInfoLocalAddresses.includes(interface: name, flags: active))
            precondition(NetworkInfoLocalAddresses.isTunnel(interface: name, flags: active))
        }
        let legacyRecord = NetworkInfoHistoryRecord(id: UUID(), queriedAt: Date(), entries: [NetworkInfoHistoryEntry(route: .domestic, result: nil, failure: .timedOut)])
        let legacyData = try JSONEncoder().encode([legacyRecord])
        precondition(NetworkInfoHistory.decode(legacyData).first?.localAddresses == nil)
        var snapshot = legacyRecord
        snapshot.localAddresses = [NetworkInfoLocalAddress(interface: "utun4", ip: "10.8.0.6", isTunnel: true)]
        let snapshotData = try JSONEncoder().encode([snapshot])
        precondition(NetworkInfoHistory.decode(snapshotData).first == snapshot)
        var local = [NetworkInfoLocalAddress(interface: "en0", ip: "192.168.1.20")]
        var localFails = false
        let localService = NetworkInfoService(monitorsPathChanges: false, historyDefaults: nil, readLocalAddresses: {
            if localFails { throw POSIXError(.EIO) }
            return local
        })
        localService.refreshLocalAddresses()
        precondition(localService.localAddresses == local)
        localService.networkDidChange()
        precondition(localService.state(.domestic).networkChanged)
        precondition(localService.localAddresses == local)
        local = []
        localService.refreshLocalAddresses()
        precondition(localService.localAddresses.isEmpty && !localService.localAddressFailed)
        localFails = true
        localService.refreshLocalAddresses()
        precondition(localService.localAddressFailed)
        localService.stop()
        precondition(!localService.localAddressFailed)
        precondition(tryValue("8.8.4.4\n") == "8.8.4.4")
        for bad in ["", "<html>8.8.4.4</html>", "::1", "1.2.3", "256.1.1.1", "01.2.3.4", "127.0.0.1", "192.168.1.1", "100.64.0.1", "224.0.0.1", "1.2.3.4/24"] {
            precondition(tryValue(bad) == nil, "Unexpected valid IP: \(bad)")
        }
        let ipip = NetworkInfoRoute.domestic.probes[1]
        precondition((try? ipip.parse(Data("当前 IP：8.8.4.4  来自于：中国".utf8))) == "8.8.4.4")
        for bad in ["IP: 8.8.4.4", "<html>8.8.4.4</html>", "当前 IP：::1 来自于：中国", "当前 IP：10.0.0.1 来自于：中国"] {
            precondition((try? ipip.parse(Data(bad.utf8))) == nil)
        }
        let url = try NetworkInfoSupport.lookupURL(ip: "8.8.4.4")
        precondition(url.scheme == "https" && url.path == "/8.8.4.4")
        let empty = Data(#"{"success":true,"ip":"8.8.4.4","country":" ","connection":{"asn":null,"isp":null,"org":" Example "}}"#.utf8)
        let details = try NetworkInfoSupport.decodeDetails(empty, expectedIP: "8.8.4.4")
        precondition(details.location == nil && details.operatorName == "Example" && details.asnDescription == "Example")
        precondition((try? NetworkInfoSupport.decodeDetails(empty, expectedIP: "1.1.1.1")) == nil)
        precondition((try? NetworkInfoSupport.decodeDetails(Data(#"{"success":false,"message":"invalid"}"#.utf8), expectedIP: "8.8.4.4")) == nil)
        let now = Date(timeIntervalSince1970: 1_000)
        var state = NetworkInfoState(result: NetworkInfoResult(ip: "8.8.4.4", checkedAt: now))
        precondition(!state.needsRefresh(now: now.addingTimeInterval(299)))
        precondition(state.needsRefresh(now: now.addingTimeInterval(300)))
        state.isStale = true
        precondition(state.needsRefresh(now: now))
        state.failure = .timedOut; state.attemptedAt = now
        precondition(!state.needsRefresh(now: now.addingTimeInterval(29)))
        precondition(state.needsRefresh(now: now.addingTimeInterval(30)))
        state.isLoading = true
        precondition(!state.needsRefresh(now: now.addingTimeInterval(500)))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkInfoMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = NetworkInfoClient(session: session)
        async let domestic = client.probe(.domestic)
        async let international = client.probe(.international)
        let (first, second) = try await (domestic, international)
        precondition(first.ip == "8.8.4.4" && second.ip == "1.1.1.1")
        precondition(first.probeHost == "myip.ipip.net") // Failed primary falls back, keeping provenance.
        precondition(second.probeHost == "api.ipify.org")
        let found = try await client.lookup(ip: first.ip)
        precondition(found.asn == 15169 && found.operatorName == "Google")
        do {
            _ = try await client.lookup(ip: second.ip)
            preconditionFailure("Expected rate limit")
        } catch { precondition(error as? NetworkInfoFailure == .rateLimited) }
        // The independently successful probe is retained when enrichment fails.
        precondition(second.ip == "1.1.1.1")
        let cancelled = Task { try await client.probe(.domestic) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Expected cancellation") }
        catch { precondition(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let service = NetworkInfoService(client: client, monitorsPathChanges: false, historyDefaults: nil)
        service.refresh()
        service.refresh() // Coalesce a second open while the first request is pending.
        for await states in service.$states.values {
            if states.count == 2 && states.values.allSatisfy({ !$0.isLoading }) { break }
        }
        precondition(service.state(.domestic).result?.details?.asn == 15169)
        precondition(service.state(.international).result?.lookupFailure == .rateLimited)
        precondition(service.history.count == 1 && service.history[0].entries.count == 2)
        precondition(service.history[0].entries.map(\.route) == [.domestic, .international])
        precondition(service.history[0].entries[1].result?.lookupFailure == .rateLimited)
        let cached = service.state(.domestic)
        service.refresh()
        precondition(service.state(.domestic) == cached)
        precondition(service.history.count == 1)
        precondition(!service.state(.international).isLoading) // Failure backoff.
        service.refresh(force: true)
        service.networkDidChange() // Supersede both in-flight requests.
        precondition(NetworkInfoRoute.allCases.allSatisfy { service.state($0).isStale && !service.state($0).isLoading })
        service.refresh()
        for await states in service.$states.values {
            if states.count == 2 && states.values.allSatisfy({ !$0.isLoading }) { break }
        }
        precondition(!service.state(.domestic).isStale)
        precondition(service.state(.domestic).result?.details?.asn == 15169)
        service.refresh(force: true)
        service.stop()
        precondition(service.states.isEmpty)
        service.refresh()
        for await states in service.$states.values {
            if states.count == 2 && states.values.allSatisfy({ !$0.isLoading }) { break }
        }
        precondition(service.state(.domestic).result?.details?.asn == 15169)
        let suiteName = "vorss.tests.network-info-history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let saved = NetworkInfoService(client: client, monitorsPathChanges: false, historyDefaults: defaults)
        saved.refresh()
        for await states in saved.$states.values {
            if states.count == 2 && states.values.allSatisfy({ !$0.isLoading }) { break }
        }
        let restored = NetworkInfoService(client: client, monitorsPathChanges: false, historyDefaults: defaults)
        precondition(restored.history == saved.history && restored.history.count == 1)
        precondition(restored.restoredAt == saved.history.first?.queriedAt)
        precondition(restored.localAddresses == saved.history.first?.localAddresses ?? [])
        for entry in saved.history[0].entries {
            precondition(restored.state(entry.route).result == entry.result)
            precondition(restored.state(entry.route).failure == entry.failure)
            precondition(!restored.state(entry.route).isLoading)
            precondition(!restored.state(entry.route).networkChanged)
            precondition(restored.state(entry.route).isStale == (entry.result != nil))
        }
        restored.deleteHistory(restored.history[0].id)
        precondition(defaults.data(forKey: NetworkInfoHistory.storageKey) == nil)
        precondition(NetworkInfoService(client: client, monitorsPathChanges: false, historyDefaults: defaults).history.isEmpty)
        saved.refresh(force: true)
        saved.clearHistory()
        for await states in saved.$states.values {
            if states.count == 2 && states.values.allSatisfy({ !$0.isLoading }) { break }
        }
        precondition(saved.history.isEmpty) // Clearing during a query does not resurrect records.
        precondition(defaults.data(forKey: NetworkInfoHistory.storageKey) == nil)
        let entries = service.history[0].entries
        let records = (0..<12).map { index in
            NetworkInfoHistoryRecord(id: UUID(), queriedAt: now.addingTimeInterval(Double(index)), entries: entries)
        }
        let bounded = NetworkInfoHistory.normalized(records + [records[0]])
        precondition(bounded.count == 10 && bounded.first?.id == records[11].id && bounded.last?.id == records[2].id)
        precondition(NetworkInfoHistory.decode(try? JSONEncoder().encode(bounded)) == bounded)
        precondition(NetworkInfoHistory.decode(Data("corrupt".utf8)).isEmpty)
        print("Network history tests passed: grouping, cache deduplication, persistence, delete, clear, limit")
        print("Network info tests passed: parsing, cache, explicit-IP lookup, independent probes, rate limits, cancellation")

        if CommandLine.arguments.contains("--live") {
            let live = NetworkInfoClient()
            for route in NetworkInfoRoute.allCases {
                do {
                    let result = try await live.probe(route)
                    let info = try await live.lookup(ip: result.ip)
                    print("Live \(route.rawValue): IPv4 OK via \(result.probeHost ?? "unknown"); location=\(info.location != nil), ISP=\(info.operatorName != nil), ASN=\(info.asn != nil)")
                } catch { print("Live \(route.rawValue): \(NetworkInfoSupport.failure(error)); URL error code=\((error as? URLError)?.code.rawValue ?? 0)") }
            }
        }
    }
    private static func tryValue(_ text: String) -> String? {
        try? NetworkInfoSupport.parseIPv4(Data(text.utf8))
    }
}
