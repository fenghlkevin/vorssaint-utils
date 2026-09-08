import Foundation

@main enum BatteryDiagnosticSnapshotTests {
    static func main() {
        var events = (0..<1000).map { "event-\($0)" }
        let snapshot = BatteryDiagnosticSnapshot(generatedAt: Date(timeIntervalSince1970: 0), summary: "状态", events: events)
        events.removeAll()
        precondition(snapshot.events.count == 1000)
        precondition(snapshot.recentEvents.count == 50)
        precondition(snapshot.recentEvents.last == "event-49")
        precondition(snapshot.report.contains("event-999"))
        precondition(snapshot.report.contains("1970-01-01T00:00:00Z"))
        let cleared = BatteryDiagnosticSnapshot(generatedAt: Date(), summary: "状态", events: [])
        precondition(cleared.recentEvents.isEmpty && !cleared.report.contains("event-"))
        precondition(snapshot.id != cleared.id)
        print("Battery diagnostic snapshot: fixed content, preview limit, full copy and empty snapshot passed")
    }
}
