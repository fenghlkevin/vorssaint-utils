// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit, signed development integration test. Never called by installation.
import AppKit
import Foundation

@main enum BatteryLiveTest {
    enum Failure: Error { case invalid(String) }
    static func main() {
        do { try run() }
        catch { fputs("LIVE_TEST_FAILED: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 3,
              ["--status", "--apply-85-and-restore"].contains(CommandLine.arguments[1]) else {
            throw Failure.invalid("usage: --status|--apply-85-and-restore EXPECTED_HELPER_CDHASH")
        }
        let writes = CommandLine.arguments[1] == "--apply-85-and-restore"
        let expected = CommandLine.arguments[2]
        guard expected.count == 40, expected.allSatisfy({ $0.isHexDigit }),
              let requirement = BatteryControlIdentifiers.requirement(for: BatteryControlIdentifiers.helperID) else {
            throw Failure.invalid("missing signing identity or expected hash")
        }
        if writes {
            for id in ["com.vorssaint.utils", "com.vorssaint.utils.dev"] {
                guard NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .filter({ $0.processIdentifier != getpid() }).isEmpty else {
                    throw Failure.invalid("close Vorssaint before isolated live test")
                }
            }
        }
        let connection = NSXPCConnection(machServiceName: BatteryControlIdentifiers.helperID, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: BatteryControlXPCProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.activate()
        defer { connection.invalidate() }
        func request(_ operation: (BatteryControlXPCProtocol, @escaping (Data) -> Void) -> Void) throws -> BatteryControlResponse {
            var finished = false
            var result: BatteryControlResponse?
            var problem: String?
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                DispatchQueue.main.async { problem = error.localizedDescription; finished = true }
            }) as? BatteryControlXPCProtocol else { throw Failure.invalid("no XPC proxy") }
            operation(proxy) { data in
                DispatchQueue.main.async { result = try? JSONDecoder().decode(BatteryControlResponse.self, from: data); finished = true }
            }
            let deadline = Date().addingTimeInterval(12)
            while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            guard finished, let result, result.version == 2, result.codeHash == expected else {
                throw Failure.invalid(problem ?? "timeout or unexpected helper identity/version")
            }
            print(String(data: result.encoded, encoding: .utf8) ?? "decode error")
            fflush(stdout)
            return result
        }
        let before = try request { $0.status(withReply: $1) }
        guard writes else { return }
        guard before.error == nil, !before.active, before.systemChargeLimitBackend == true,
              let original = before.systemLimitReadback,
              before.systemChargeLimits?.contains(original) == true,
              before.systemChargeLimits?.contains(85) == true else {
            throw Failure.invalid("backend not idle/compatible; no write attempted")
        }
        print("BASELINE_LIMIT=\(original)")
        var attempted = false
        var restored = false
        defer {
            if attempted && !restored {
                print("TEST_CLEANUP: requesting original limit restoration")
                _ = try? request { $0.restore(withReply: $1) }
            }
        }
        var config = BatteryControlConfiguration()
        config.enabled = true; config.limit = 85; config.allowSystemChargeLimit = true
        let data = try JSONEncoder().encode(config)
        attempted = true
        var response = try request { $0.update(data, withReply: $1) }
        let deadline = Date().addingTimeInterval(30)
        while response.error == nil && Date() < deadline {
            if response.active && response.systemLimitReadback == 85 && response.systemPolicyLimit == 85 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            response = try request { $0.status(withReply: $1) }
        }
        let applied = response.error == nil && response.active && response.systemLimitReadback == 85
        print("LIMIT_READBACK_85=\(applied) POLICY_85=\(response.systemPolicyLimit == 85)")
        let restoreResult = try request { $0.restore(withReply: $1) }
        restored = restoreResult.error == nil && !restoreResult.active && restoreResult.systemLimitReadback == original
        print("ORIGINAL_LIMIT_RESTORED=\(restored) expected=\(original)")
        guard restored else { throw Failure.invalid("RESTORE UNCONFIRMED: helper retains journal; inspect immediately") }
        guard applied else { throw Failure.invalid("85% setting not confirmed; original setting restored") }
        print("LIVE_TEST_PASSED (setting and restore; physical charge state must be observed separately)")
    }
}
