import Foundation

@main
struct AwayLockWakeTests {
    static func main() {
        precondition(!AwayLockSupport.canWakeDisplays(onlineCount: 0, asleepCount: 0))
        precondition(!AwayLockSupport.canWakeDisplays(onlineCount: 2, asleepCount: 1))
        precondition(!AwayLockSupport.canWakeDisplays(onlineCount: 2, asleepCount: 0))
        precondition(!AwayLockSupport.canWakeDisplays(onlineCount: 1, asleepCount: 2))
        precondition(AwayLockSupport.canWakeDisplays(onlineCount: 1, asleepCount: 1))
        precondition(AwayLockSupport.canWakeDisplays(onlineCount: 2, asleepCount: 2))
        print("away-lock-wake: 6 checks passed")
    }
}
