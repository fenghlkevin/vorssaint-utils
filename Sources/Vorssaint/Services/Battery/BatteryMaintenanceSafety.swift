// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum BatteryMaintenanceSafety {
    /// A live PID is not permission to stop a controller. The shared lock must
    /// stay held from these checks until launchd confirms the job has exited.
    static func canStopService(lockHeld: Bool, command: BatteryCommand?, jobReadable: Bool) -> Bool {
        lockHeld && command == .automatic && jobReadable
    }
}
