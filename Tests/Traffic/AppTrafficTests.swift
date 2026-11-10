import Foundation

@main struct AppTrafficTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var ledger = AppTrafficLedger.restore(nil, bootID: 10, bootDate: now, now: now)
        ledger.add(id: "app:a", name: "A", appPath: "/A.app", child: "helper", down: 100, up: 20, now: now)
        ledger.add(id: "app:a", name: "A", appPath: "/A.app", child: "helper", down: 50, up: 10, now: now)
        ledger.add(id: "app:a", name: "A", appPath: "/A.app", child: "bad", down: .nan, up: 10, now: now)
        precondition(ledger.entries["app:a"]?.total == 180)
        precondition(ledger.entries["app:a"]?.children["helper"] == 180)
        let data = try JSONEncoder().encode(ledger)
        let resumed = AppTrafficLedger.restore(data, bootID: 10, bootDate: now, now: now.addingTimeInterval(60))
        precondition(resumed.entries.count == 1 && resumed.interrupted && resumed.startedAt == now)
        let rebooted = AppTrafficLedger.restore(data, bootID: 11, bootDate: now, now: now)
        precondition(rebooted.entries.isEmpty && !rebooted.interrupted)
        precondition(AppTrafficLedger.restore(Data("bad".utf8), bootID: 10, bootDate: now, now: now).entries.isEmpty)
        precondition(resumed.includesLoopbackSince == nil, "old records remain readable without claiming proxy coverage")
        ledger.includesLoopbackSince = now
        let upgraded = AppTrafficLedger.restore(try JSONEncoder().encode(ledger), bootID: 10, bootDate: now, now: now)
        precondition(upgraded.includesLoopbackSince == now)
        ledger.add(id: "app:a", name: "A / Shared", appPath: "/A.app", child: "helper", down: 0, up: 0, now: now)
        precondition(ledger.entries["app:a"]?.name == "A / Shared")
        var parser = NetworkProcessDeltaStreamParser()
        precondition(parser.consumeCSVLine("time,,bytes_in,bytes_out,") == nil)
        _ = parser.consumeCSVLine("12:00,A.123,9000,8000,")
        precondition(parser.consumeCSVLine("time,,bytes_in,bytes_out,") == nil)
        _ = parser.consumeCSVLine("12:01,A.123,100,20,")
        let delta = parser.consumeCSVLine("time,,bytes_in,bytes_out,")
        precondition(delta?.first?.bytesIn == 100 && delta?.first?.bytesOut == 20)
        precondition(parser.consumeCSVLine("time,,bytes_in,bytes_out,") == [])
        parser.reset()
        precondition(parser.consumeCSVLine("time,,bytes_in,bytes_out,") == nil)
        print("App traffic: persistence, reboot, invalid data, aggregation, initial baseline and stream reset passed")
    }
}
