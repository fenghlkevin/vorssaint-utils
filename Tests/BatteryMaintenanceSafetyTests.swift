import Foundation

@main enum BatteryMaintenanceSafetyTests {
    static func main() {
        precondition(BatteryMaintenanceSafety.canStopService(lockHeld: true, command: .automatic, jobReadable: true))
        for locked in [false, true] {
            for readable in [false, true] {
                for command in [BatteryCommand?.none, .some(.pause), .some(.discharge), .some(.full)] {
                    precondition(!BatteryMaintenanceSafety.canStopService(lockHeld: locked, command: command, jobReadable: readable))
                }
                if !locked || !readable {
                    precondition(!BatteryMaintenanceSafety.canStopService(lockHeld: locked, command: .automatic, jobReadable: readable))
                }
            }
        }
        print("Battery maintenance: lock, hardware and launchd safety gates passed")
    }
}
