import Foundation

@main
struct AwayLockScreenControlTests {
    @MainActor
    static func main() async {
        var sent = 0
        var polls = 0
        let alreadyLocked = await AwayLockScreenControl.lock(sessionLocked: { true }, sendShortcut: { sent += 1; return true }, wait: {})
        precondition(alreadyLocked == .locked && sent == 0)
        let unknown = await AwayLockScreenControl.lock(sessionLocked: { nil }, sendShortcut: { sent += 1; return true }, wait: {})
        guard case .failed = unknown else { fatalError("Unknown session must fail closed") }
        precondition(sent == 0)
        let denied = await AwayLockScreenControl.lock(sessionLocked: { false }, sendShortcut: { false }, wait: { polls += 1 })
        guard case .failed = denied else { fatalError("Denied shortcut must fail") }
        precondition(polls == 0)
        let confirmed = await AwayLockScreenControl.lock(sessionLocked: { polls >= 3 }, sendShortcut: { sent += 1; return true }, wait: { polls += 1 })
        precondition(confirmed == .locked && sent == 1 && polls == 3)
        polls = 0; sent = 0
        let timeout = await AwayLockScreenControl.lock(sessionLocked: { false }, sendShortcut: { sent += 1; return true }, wait: { polls += 1 })
        guard case .failed = timeout else { fatalError("Sending keys is not lock confirmation") }
        precondition(sent == 1 && polls == 20)
        polls = 0; sent = 0
        let cancelled = await AwayLockScreenControl.lock(sessionLocked: { false }, sendShortcut: { sent += 1; return true }, wait: { throw CancellationError() })
        guard case .failed = cancelled else { fatalError("Cancelled confirmation must fail") }
        precondition(sent == 1 && polls == 0)
        sent = 0
        let task = Task { @MainActor in
            await AwayLockScreenControl.lock(sessionLocked: { false }, sendShortcut: { sent += 1; return true }, wait: {})
        }
        task.cancel()
        let beforeSend = await task.value
        guard case .failed = beforeSend else { fatalError("Cancelled request must not post keys") }
        precondition(sent == 0)
        let now = Date(timeIntervalSince1970: 1000)
        var wake = AwayLockReturnWake()
        func consume(_ enabled: Bool = true, _ locked: Bool = true, _ online: Int = 2,
                     _ asleep: Int = 2, _ at: Date = now) -> Bool {
            wake.consumeReturn(enabled: enabled, locked: locked, online: online, asleep: asleep, now: at)
        }
        precondition(!consume()) // Manual locks cannot grant wake eligibility.
        wake.armed = true
        precondition(!consume(false) && !wake.armed)
        wake.armed = true
        precondition(!consume(true, false))
        wake.armed = true
        precondition(!consume(true, true, 0, 0))
        wake.armed = true
        precondition(!consume(true, true, 2, 1)) // Never wake an already lit display setup.
        wake.armed = true
        precondition(consume() && !consume()) // One shot even with repeated nearby observations.
        wake.armed = true
        precondition(!consume(true, true, 2, 2, now.addingTimeInterval(119)))
        wake.armed = true
        precondition(consume(true, true, 2, 2, now.addingTimeInterval(120)))
        func fast(_ values: [(Int, Double)]) -> Bool {
            AwayLockSupport.hasFastReturn(samples: values.map { (value: $0.0, date: now.addingTimeInterval($0.1)) }, threshold: -74, now: now)
        }
        precondition(!fast([]) && !fast([(-60, 0)]))
        precondition(fast([(-74, -1), (-73, 0)]))
        precondition(!fast([(-80, -1), (-60, 0)]))
        precondition(!fast([(-60, -1), (-80, 0)]))
        precondition(!fast([(-60, -5), (-60, 0)]))
        precondition(!fast([(-60, -6), (-60, -5)]))
        precondition(!fast([(-60, 0), (-60, 1)]))
        precondition(!fast([(-60, -0.1), (-60, 0)]))
        precondition(!fast([(-60, -1), (127, 0)]))
        print("away-lock: fast return accepts consecutive fresh signals, rejects spikes, stale, future and duplicate observations")
        var unlock = AwayLockReturnUnlock()
        precondition(!unlock.consume(enabled: true, locked: true, now: now))
        unlock.armed = true
        precondition(!unlock.consume(enabled: false, locked: true, now: now) && !unlock.armed)
        unlock.armed = true
        precondition(!unlock.consume(enabled: true, locked: false, now: now))
        unlock.armed = true
        precondition(unlock.consume(enabled: true, locked: true, now: now))
        precondition(!unlock.consume(enabled: true, locked: true, now: now))
        unlock.armed = true
        precondition(!unlock.consume(enabled: true, locked: true, now: now.addingTimeInterval(119)))
        unlock.armed = true
        precondition(unlock.consume(enabled: true, locked: true, now: now.addingTimeInterval(120)))

        var reads = 0, submissions = 0, preparation = 0, ticks = 0
        func runUnlock(allowed: @escaping @MainActor () -> Bool = { true },
                       locked: @escaping @MainActor () -> Bool? = { true },
                       secret: String? = "test only", ready: Bool = true) async -> AwayLockAutoUnlock.Result {
            await AwayLockAutoUnlock.run(allowed: allowed, locked: locked,
                password: { reads += 1; return secret },
                prepare: { preparation += 1; return ready },
                submit: { _ in submissions += 1; return true },
                wait: { ticks += 1 })
        }
        let watchUnlock = await runUnlock(locked: { false })
        precondition(watchUnlock == .unlocked && reads == 0 && submissions == 0)
        let disabledUnlock = await runUnlock(allowed: { false })
        precondition(disabledUnlock == .cancelled && preparation == 0)
        let unknownUnlock = await runUnlock(locked: { nil })
        guard case .failed = unknownUnlock else { fatalError("Unknown lock state must not type") }
        precondition(reads == 0)
        let noWindow = await runUnlock(ready: false)
        guard case .failed = noWindow else { fatalError("Missing loginwindow must fail") }
        precondition(reads == 0 && submissions == 0)
        let missingSecret = await runUnlock(secret: nil)
        guard case .failed = missingSecret else { fatalError("Missing password must fail") }
        precondition(submissions == 0)
        let failedUnlock = await runUnlock()
        guard case .failed = failedUnlock else { fatalError("Posting keys is not proof of unlock") }
        precondition(submissions == 1)
        submissions = 0
        let successUnlock = await runUnlock(locked: { submissions == 0 })
        precondition(successUnlock == .unlocked && submissions == 1)
        ticks = 0; reads = 0; submissions = 0
        let cancelledDuringWait = await runUnlock(allowed: { ticks < 4 })
        precondition(cancelledDuringWait == .cancelled && reads == 0 && submissions == 0)
        ticks = 0
        let watchDuringWait = await runUnlock(locked: { ticks < 4 })
        precondition(watchDuringWait == .unlocked && reads == 0 && submissions == 0)
        let deniedSubmission = await AwayLockAutoUnlock.run(allowed: { true }, locked: { true },
            password: { "test only" }, prepare: { true }, submit: { _ in false }, wait: {})
        guard case .failed = deniedSubmission else { fatalError("Missing secure field must fail") }
        let cancelledTask = Task { @MainActor in await runUnlock() }
        cancelledTask.cancel()
        let cancelledUnlock = await cancelledTask.value
        precondition(cancelledUnlock == .cancelled && submissions == 0)
        print("away-lock: 15 lock/wake + 7 unlock eligibility + 11 unlock flow scenarios passed (no real keyboard, power or Keychain operations)")
    }
}
