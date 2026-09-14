import Foundation

@main struct BatteryTelemetryTests {
    static func main() {
        var tracker = BatteryTelemetryTracker()
        let start = Date(timeIntervalSince1970: 1000)
        let first = tracker.observe(at: start, percent: 90, external: true, charging: false, watts: 0)
        precondition(first.contains("基线"))
        let small = tracker.observe(at: start.addingTimeInterval(30), percent: 89, external: true, charging: false, watts: -0.05)
        precondition(small.contains("微小放电读数") && small.contains("90%→89%") && small.contains("状态变化"))
        let missing = tracker.observe(at: start.addingTimeInterval(600), percent: nil, external: false, charging: false, watts: nil)
        precondition(missing.contains("期间供电过程未知") && missing.contains("电池功率未知"))
        let nan = tracker.observe(at: start.addingTimeInterval(630), percent: 88, external: true, charging: true, watts: .nan)
        precondition(nan.contains("电池功率未知") && !nan.contains("电量变化"))
        tracker = BatteryTelemetryTracker()
        precondition(tracker.observe(at: start, percent: 80, external: false, charging: false, watts: -10).contains("基线"))
        print("Battery telemetry tests passed")
    }
}
