// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import ServiceManagement

/// Explicit registration recovery. Never deletes the root recovery journal.
enum BatteryRegistrationRepair {
    /// Installer-only phases. Never infer successful control from registration alone.
    static func installPhaseAndExit(prepare: Bool) -> Never {
        func fail(_ message: String) -> Never { print("Battery install failed: \(message)"); exit(1) }
        let runningApps = ["com.vorssaint.utils", "com.vorssaint.utils.dev"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }.filter { $0.processIdentifier != getpid() }
        guard runningApps.isEmpty else { fail("close other Vorssaint instances before installation") }
        let service = SMAppService.daemon(plistName: BatteryControlIdentifiers.plistName)
        if prepare && service.status == .notRegistered {
            print("BATTERY_REINSTALL=0"); exit(0)
        }
        // After a safe bootout, macOS 27 may retain a .notFound registration.
        // Register the current embedded helper directly, as the interactive
        // authorize path does; unregistering that absent job returns EPERM.
        if !prepare && (service.status == .notRegistered || service.status == .notFound) {
            do { try service.register() }
            catch { fail("register: \(error). App retained; retry after checking Login Items & Extensions.") }
        }
        guard service.status == .enabled else {
            fail("registration status=\(service.status.rawValue); user approval or registration repair required")
        }
        guard let requirement = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.helperID) else {
            fail("missing signing certificate")
        }
        let connection = NSXPCConnection(machServiceName: BatteryControlIdentifiers.helperID, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: BatteryControlXPCProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.activate()
        var completed = false
        var response: BatteryControlResponse?
        var failure: String?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { failure = String(describing: error); completed = true }
        } as? BatteryControlXPCProtocol
        guard let proxy else { fail("cannot create authenticated XPC proxy") }
        let reply: (Data) -> Void = { data in
            DispatchQueue.main.async {
                response = try? JSONDecoder().decode(BatteryControlResponse.self, from: data)
                completed = true
            }
        }
        if prepare { proxy.prepareForRemoval(withReply: reply) }
        else { proxy.status(withReply: reply) }
        let deadline = Date().addingTimeInterval(10)
        while !completed && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        connection.invalidate()
        guard completed, let response, !prepare || response.error == nil else {
            fail(failure ?? response?.error ?? "no valid acknowledgement within 10 seconds")
        }
        if prepare {
            guard !response.active else { fail("old helper still controls charging") }
            print("Old helper confirmed safe retirement; unregistering.")
            completed = false
            service.unregister { error in
                DispatchQueue.main.async { failure = error.map { String(describing: $0) }; completed = true }
            }
            let removalDeadline = Date().addingTimeInterval(20)
            while !completed && Date() < removalDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            guard completed, failure == nil, service.status == .notRegistered else {
                fail(failure ?? "unregister did not complete")
            }
            print("BATTERY_REINSTALL=1")
        } else {
            guard let expected = BatteryControlIdentifiers.embeddedCodeHash(),
                  response.version == BatteryControlResponse().version,
                  response.codeHash == expected else { fail("helper protocol/code hash does not match installed bundle") }
            print("Battery handshake verified: codeHash=\(expected), command=\(response.command), active=\(response.active)")
            if let error = response.error { print("Charging control unavailable (connection verified): \(error)") }
        }
        exit(0)
    }

    static func runAndExit() -> Never {
        let others = ["com.vorssaint.utils", "com.vorssaint.utils.dev"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }.filter { $0.processIdentifier != getpid() }
        guard others.isEmpty else {
            print("Close Vorssaint instances before resetting battery registration."); exit(1)
        }
        var safelyRetired = false
        if CommandLine.arguments.contains("--retire-and-repair-battery-registration") {
            _ = NSApplication.shared
            guard BatteryControlIdentifiers.embeddedHelperMatchesSigner() else {
                print("Embedded helper signature does not match this App."); exit(1)
            }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(BatteryControlIdentifiers.helperID)").path
            let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
            var finished = false
            AdminShell.runWithResult(quoted + " --retire-for-registration-repair",
                prompt: "安全迁移 Vorssaint 电池后台；验证控制锁与恢复记录后替换旧服务。") { status, output in
                print(output)
                safelyRetired = status == 0 && output.contains("BATTERY_MAINTENANCE_RETIRED=1")
                finished = true
            }
            let deadline = Date().addingTimeInterval(660)
            while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            guard finished, safelyRetired else { print("Safe retirement not confirmed; registration unchanged."); exit(1) }
        }
        var info = stat()
        let noRecoveryStorage = lstat("/Library/Application Support/VorssaintBatteryControl", &info) != 0 && errno == ENOENT
        if !noRecoveryStorage && !safelyRetired {
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
        if service.status == .notRegistered || service.status == .notFound { register() }
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
