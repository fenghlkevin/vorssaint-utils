// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import ServiceManagement

/// Explicit registration recovery. Never deletes the root recovery journal.
enum BatteryRegistrationRepair {
    static func runAndExit() -> Never {
        let others = ["com.vorssaint.utils", "com.vorssaint.utils.dev"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }.filter { $0.processIdentifier != getpid() }
        guard others.isEmpty else {
            print("Close Vorssaint instances before resetting battery registration."); exit(1)
        }
        var info = stat()
        let noRecoveryStorage = lstat("/Library/Application Support/VorssaintBatteryControl", &info) != 0 && errno == ENOENT
        if !noRecoveryStorage {
            // This narrowly-scoped migration is safe only after a fresh,
            // read-only hardware check proves charging and AC are automatic.
            guard CommandLine.arguments.contains("--recover-automatic-registration"),
                  let hardware = BatteryControlHardware(smc: SMCClient()),
                  (try? hardware.state()) == .automatic else {
                print("Recovery storage exists; control is not proven automatic."); exit(1)
            }
            print("Control is automatic; preserving recovery journal for the updated daemon.")
        }
        let service = SMAppService.daemon(plistName: BatteryControlIdentifiers.plistName)
        var completed = false
        var succeeded = false
        func register() {
            do {
                try service.register()
                print("Battery daemon registered; status=\(service.status.rawValue)")
                if service.status == .requiresApproval {
                    print("User approval required in System Settings > Login Items & Extensions.")
                    SMAppService.openSystemSettingsLoginItems()
                }
                succeeded = true
            } catch { print("Battery registration failed: \(error)") }
            completed = true
        }
        if service.status == .notRegistered { register() }
        else {
            service.unregister { error in
                DispatchQueue.main.async {
                    if let error { print("Battery unregister failed: \(error)"); completed = true; return }
                    print("Old battery registration removed; launchd completed removal.")
                    register()
                }
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while !completed && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !completed { print("Registration operation timed out; no forced removal performed.") }
        exit(completed && succeeded ? 0 : 1)
    }
}
