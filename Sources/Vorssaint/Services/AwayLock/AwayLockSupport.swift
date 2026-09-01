// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AwayLockSupport {
    static func median(_ samples: [Int]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    static func isNear(rssi: Int, threshold: Int, returnMargin: Int, wasNear: Bool) -> Bool {
        rssi >= threshold + (wasNear ? 0 : max(0, returnMargin))
    }

    static func shouldStartCountdown(weakSince: Date?, now: Date, requiredSeconds: Int) -> Bool {
        guard let weakSince else { return false }
        return now.timeIntervalSince(weakSince) >= Double(max(1, requiredSeconds))
    }

    /// Silence is meaningful only after the peripheral has been observed for at
    /// least one complete loss window. Some nearby peripherals advertise only
    /// briefly and then go quiet (especially once connected); treating a single
    /// discovery burst as a departure makes proximity locking unsafe.
    static func canInferDepartureFromSilence(firstSeen: Date?, lastSeen: Date?,
                                             requiredObservationSeconds: Int) -> Bool {
        guard let firstSeen, let lastSeen else { return false }
        return lastSeen.timeIntervalSince(firstSeen) >= Double(max(1, requiredObservationSeconds))
    }
}
