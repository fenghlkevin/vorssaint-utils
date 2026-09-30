// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One opportunity per confirmed automatic lock. A skipped return is never retried.
struct AwayLockReturnWake {
    var armed = false
    private var lastAttempt: Date?

    mutating func consumeReturn(enabled: Bool, locked: Bool, online: Int, asleep: Int,
                                now: Date) -> Bool {
        let eligible = armed
        armed = false
        guard eligible, enabled, locked, online > 0, asleep == online,
              lastAttempt.map({ now.timeIntervalSince($0) >= 120 }) ?? true else { return false }
        lastAttempt = now
        return true
    }
}
