import Foundation

@main struct NetworkChainTests {
    static func main() {
        let fixture = """
        p101
        cCodex Service
        f10
        PTCP
        n127.0.0.1:50100->127.0.0.1:7890
        TST=ESTABLISHED
        p202
        cFlClashCore
        f5
        PTCP
        n127.0.0.1:7890
        TST=LISTEN
        f6
        PTCP
        n127.0.0.1:7890->127.0.0.1:50100
        TST=ESTABLISHED
        f7
        PTCP
        n192.168.1.2:50101->1.2.3.4:443
        TST=ESTABLISHED
        p303
        cIPv6 App
        f8
        PTCP
        n[::1]:50200->[::1]:8080
        TST=ESTABLISHED
        f9
        PUDP
        n127.0.0.1:1234->127.0.0.1:5678
        TST=ESTABLISHED
        """
        let rows = NetworkChainSupport.parse(fixture)
        precondition(rows.count == 5)
        let client = rows.first { $0.pid == 101 }!
        precondition(client.process == "Codex Service" && client.isLoopback)
        let server = NetworkChainSupport.peer(of: client, in: rows)!
        precondition(server.pid == 202 && NetworkChainSupport.incoming(server, in: rows))
        precondition(!NetworkChainSupport.incoming(client, in: rows))
        precondition(NetworkChainSupport.peer(of: client, in: [client]) == nil)
        let external = rows.first { $0.remote == "1.2.3.4:443" }!
        precondition(!external.isLoopback && NetworkChainSupport.peer(of: external, in: rows) == nil)
        precondition(rows.first { $0.pid == 303 }!.isLoopback)
        precondition(NetworkChainSupport.parse(fixture + "\np101\ncCodex Service\nf10\nPTCP\nn127.0.0.1:50100->127.0.0.1:7890\nTST=ESTABLISHED").count == 5)
        precondition(NetworkChainSupport.appPath(fromProcessPath: "/Applications/Codex.app/Contents/MacOS/codex") == "/Applications/Codex.app")
        precondition(NetworkChainSupport.appPath(fromProcessPath: "/usr/bin/java") == nil)
        precondition(NetworkChainSupport.parse("garbage").isEmpty)
        let flowFixture = """
        time,,bytes_in,bytes_out,
        12:00,Codex Service.101,999999,999999,
        12:00,tcp4 127.0.0.1:50100<->127.0.0.1:7890,100,200,
        12:00,tcp4 127.0.0.1:50101<->127.0.0.1:7890,20,30,
        12:00,tcp4 127.0.0.1:8021<->*:*,,,
        12:00,IPv6 App.303,999,999,
        12:00,tcp6 ::1.50200<->::1.8080,40,50,
        12:00,tcp6 ::1.50201<->::1.8080,,,
        12:00,tcp6 ::1.50202<->::1.8080,-1,30,
        12:00,tcp6 ::1.50203<->::1.8080,nan,30,
        """
        let flows = NetworkFlowSupport.parse(flowFixture)
        precondition(flows.count == 3)
        precondition(flows[client.id]?.downloaded == 100 && flows[client.id]?.uploaded == 200)
        precondition(flows["101|127.0.0.1:50101|127.0.0.1:7890"]?.total == 50)
        precondition(flows[rows.first { $0.pid == 303 }!.id]?.total == 90)
        precondition(flows[server.id] == nil, "Never borrow reverse peer or process-total bytes")
        precondition(NetworkFlowSupport.matchesSource(local: client.local, remote: client.remote, sourceIP: "127.0.0.1", sourcePort: "50100", proxyPort: 7890))
        precondition(!NetworkFlowSupport.matchesSource(local: client.local, remote: client.remote, sourceIP: "127.0.0.1", sourcePort: "50101", proxyPort: 7890))
        precondition(!NetworkFlowSupport.matchesSource(local: client.local, remote: "10.0.0.1:7890", sourceIP: "127.0.0.1", sourcePort: "50100", proxyPort: 7890))
        var tracker = NetworkFlowRateTracker()
        precondition(tracker.sample(flows, now: 1)[client.id]?.downloadRate == nil)
        var next = flows
        next[client.id] = .init(downloaded: 130, uploaded: 260)
        precondition(tracker.sample(next, now: 4)[client.id]?.downloadRate == 10)
        precondition(tracker.sample(flows, now: 7)[client.id]?.downloadRate == nil, "counter reset is not a spike")
        precondition(tracker.sample(next, now: 40)[client.id]?.downloadRate == nil, "stale samples are not live rates")
        tracker.reset()
        precondition(tracker.sample(next, now: 41)[client.id]?.downloadRate == nil)
        print("Per-target traffic: exact TCP tuples, IPv6, independent byte counters, missing/reset counters, gap rates and proxy source matching passed")
        print("Network chains: IPv4/IPv6, listener direction, exact reverse endpoints, no inferred downstream, deduplication and process-path matching passed")
    }
}
