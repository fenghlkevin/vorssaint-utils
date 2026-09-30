// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Absolute deadlines keep timers accurate across sleep and delayed UI ticks.
struct IslandTimerClock {
    private(set) var duration = 0
    private var deadline: Date?
    private var pausedSeconds: Int?
    var isPaused: Bool { pausedSeconds != nil }
    var isActive: Bool { deadline != nil }

    mutating func start(seconds: Int, now: Date = Date()) {
        guard seconds > 0 else { return }
        duration = min(seconds, 86_399)
        deadline = now.addingTimeInterval(Double(duration))
        pausedSeconds = nil
    }

    func remaining(at now: Date = Date()) -> Int {
        pausedSeconds ?? max(0, Int((deadline?.timeIntervalSince(now) ?? 0).rounded(.up)))
    }

    func hasFinished(at now: Date = Date()) -> Bool {
        isActive && !isPaused && remaining(at: now) == 0
    }

    mutating func togglePause(now: Date = Date()) {
        guard isActive, !hasFinished(at: now) else { return }
        if let pausedSeconds {
            deadline = now.addingTimeInterval(Double(pausedSeconds))
            self.pausedSeconds = nil
        } else {
            pausedSeconds = remaining(at: now)
        }
    }

    mutating func stop() { deadline = nil; pausedSeconds = nil; duration = 0 }
}

struct IslandRunningTimer: Equatable {
    let title: String
    let remaining: Int
    let total: Int
    let paused: Bool
}

enum IslandUtilityLayout {
    static func panelWidth(_ codexWidth: Double) -> Double { min(max(codexWidth, 520), 760) }
    static func time(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
