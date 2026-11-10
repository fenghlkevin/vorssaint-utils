import Foundation

@main struct NetworkChainLiveTests {
    static func main() {
        let socketResult = BoundedProcessRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-FpcfPnT"], timeout: 4, maxOutputBytes: 4 * 1024 * 1024)
        let counterResult = BoundedProcessRunner.run("/usr/bin/nettop", ["-n", "-x", "-J", "bytes_in,bytes_out", "-L", "1"], timeout: 3, maxOutputBytes: 4 * 1024 * 1024)
        precondition(!socketResult.timedOut && socketResult.status == 0)
        precondition(!counterResult.timedOut && counterResult.status == 0)
        let sockets = NetworkChainSupport.parse(String(decoding: socketResult.output, as: UTF8.self)).filter { $0.state == "ESTABLISHED" }
        let counters = NetworkFlowSupport.parse(String(decoding: counterResult.output, as: UTF8.self))
        let matched = sockets.compactMap { counters[$0.id] }
        precondition(!matched.isEmpty, "No exact per-flow match on this host")
        precondition(matched.contains { $0.total > 0 }, "Expected observed traffic on this active host")
        print("Live target traffic: \(matched.count)/\(sockets.count) active TCP endpoints have exact pid/local/remote byte counters")
    }
}
