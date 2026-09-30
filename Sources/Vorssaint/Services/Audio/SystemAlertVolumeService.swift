// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// Standard Additions exposes alert volume independently of the output device
/// scalar. Changing the alert route does not change this global relative level.
final class SystemAlertVolumeService: ObservableObject {
    static let shared = SystemAlertVolumeService()

    @Published private(set) var volume: Double?
    @Published private(set) var failed = false
    private var previousVolume = 0.5
    private var generation = 0
    private var reading = false
    private var writing = false
    private var pendingWrite: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.vorssaint.utils.alert-volume")

    func refresh() {
        guard !reading, !writing else { return }
        reading = true
        let revision = generation
        queue.async { [weak self] in
            let value = Self.readVolume()
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                guard self.generation == revision else { return }
                self.volume = value
                self.failed = value == nil
                if let value, value > 0 { self.previousVolume = value }
            }
        }
    }

    func toggle() {
        guard let volume else { return }
        setVolume(volume > 0 ? 0 : previousVolume)
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        let percent = Int((min(max(value, 0), 1) * 100).rounded())
        if let volume, volume > 0 { previousVolume = volume }
        volume = Double(percent) / 100
        failed = false
        generation += 1
        let revision = generation
        writing = true
        pendingWrite?.cancel()
        // Collapse a slider drag into short, serialized writes, off the UI
        // thread. Never send output volume or output muted in this command.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == revision else { return }
            self.queue.async {
                let result = AppleScriptRunner.run("set volume alert volume \(percent)")
                let actual = Self.readVolume()
                DispatchQueue.main.async {
                    guard self.generation == revision else { return }
                    self.writing = false
                    self.pendingWrite = nil
                    self.volume = actual
                    self.failed = !result.ok || actual == nil
                    if let actual, actual > 0 { self.previousVolume = actual }
                }
            }
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private static func readVolume() -> Double? {
        let result = AppleScriptRunner.run("get alert volume of (get volume settings)")
        guard result.ok,
              let percent = Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
              percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent / 100
    }
}
