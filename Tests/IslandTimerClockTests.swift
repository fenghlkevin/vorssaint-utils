import Foundation

@main struct IslandTimerClockTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1000)
        var clock = IslandTimerClock()
        clock.start(seconds: 0, now: now)
        precondition(!clock.isActive)
        clock.start(seconds: 5, now: now)
        precondition(clock.remaining(at: now.addingTimeInterval(1.2)) == 4)
        clock.togglePause(now: now.addingTimeInterval(2))
        precondition(clock.isPaused && clock.remaining(at: now.addingTimeInterval(100)) == 3)
        precondition(!clock.hasFinished(at: now.addingTimeInterval(100)))
        clock.togglePause(now: now.addingTimeInterval(100))
        precondition(!clock.isPaused && clock.remaining(at: now.addingTimeInterval(101)) == 2)
        precondition(clock.hasFinished(at: now.addingTimeInterval(103)))
        clock.togglePause(now: now.addingTimeInterval(104))
        precondition(!clock.isPaused, "An expired timer must complete instead of pausing at zero")
        clock.start(seconds: 60, now: now)
        precondition(clock.hasFinished(at: now.addingTimeInterval(3600)), "Sleep does not postpone a deadline")
        clock.start(seconds: 90, now: now)
        clock.togglePause(now: now)
        clock.start(seconds: 10, now: now)
        precondition(!clock.isPaused && clock.remaining(at: now) == 10)
        clock.stop()
        precondition(!clock.isActive && clock.remaining(at: now) == 0 && !clock.hasFinished(at: now))
        precondition(IslandUtilityLayout.time(3661) == "1:01:01")
        precondition(IslandUtilityLayout.time(5) == "00:05")
        for width in [400.0, 520, 600, 760, 900] {
            precondition(IslandUtilityLayout.panelWidth(width) == min(max(width, 520), 760))
        }
        print("PASS: timer deadlines, seconds, pause/resume, sleep, restart, cancellation and shared width")
    }
}
