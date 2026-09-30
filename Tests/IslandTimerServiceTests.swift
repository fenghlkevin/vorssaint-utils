import Foundation

// Standalone service harness: no app windows or completion sounds.
final class DynamicIslandService {
    static let shared = DynamicIslandService()
    var activations = 0
    func activateTimeReminder() { activations += 1 }
}

@main struct IslandTimerServiceTests {
    static func main() {
        UserDefaults.standard.setVolatileDomain([
            "dynamicIsland.calendarEnabled": false,
            "dynamicIsland.breakEnabled": false,
            "dynamicIsland.completionSoundEnabled": false
        ], forName: UserDefaults.argumentDomain)
        let service = TimeReminderService.shared
        service.startFocus(minutes: 25)
        precondition(service.runningTimer?.total == 1500)
        service.toggleCountdownPause()
        precondition(service.runningTimer?.paused == true, "Focus must support pause too")
        let remaining = service.remainingSeconds
        service.tick()
        precondition(service.remainingSeconds == remaining)
        service.toggleCountdownPause()
        precondition(service.runningTimer?.paused == false)
        service.stopTimer()
        precondition(service.runningTimer == nil && service.presentation == nil)
        service.startCountdown(title: "秒级验证", seconds: 1)
        precondition(service.runningTimer?.total == 1)
        Thread.sleep(forTimeInterval: 1.1)
        service.tick()
        precondition(service.isCompletionPresented && service.runningTimer == nil)
        precondition(DynamicIslandService.shared.activations == 1)
        service.tick()
        precondition(DynamicIslandService.shared.activations == 1, "Completion must only activate once")
        service.startCountdown(title: "新计时器", seconds: 90)
        precondition(!service.isCompletionPresented && service.runningTimer?.total == 90)
        service.stopTimer()
        precondition(service.presentation == nil)
        print("PASS: focus pause/resume, second-level completion, single alert and restart after completion")
    }
}
