// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AwayLockSupport {
    /// Reserve a complete scan window after a pause before silence can expire.
    static func canPauseScan(readings: [(near: Bool, lastSeen: Date?)], now: Date,
                             pauseSeconds: TimeInterval, scanSeconds: TimeInterval,
                             lossSeconds: Int, requiresContinuousScan: Bool) -> Bool {
        guard !requiresContinuousScan, !readings.isEmpty else { return false }
        return readings.allSatisfy { reading in
            guard reading.near, let seen = reading.lastSeen, seen <= now else { return false }
            return now.timeIntervalSince(seen) + pauseSeconds + scanSeconds < Double(lossSeconds)
        }
    }

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

    /// A missing or unreliable reading can suppress locking, but it is not proof
    /// that a device returned. Return requires fresh, explicitly-near readings
    /// sufficient to clear the policy that caused the lock.
    static func hasConfirmedReturn(policy: String, primaryID: String,
                                   readings: [(id: String, near: Bool)]) -> Bool {
        guard !readings.isEmpty else { return false }
        switch policy {
        case "allAway": return readings.contains(where: \.near)
        case "anyAway": return readings.allSatisfy(\.near)
        case "primaryAway": return readings.first(where: { $0.id == primaryID })?.near == true
        case "majorityAway": return readings.filter(\.near).count > readings.count / 2
        default: return false
        }
    }
}
