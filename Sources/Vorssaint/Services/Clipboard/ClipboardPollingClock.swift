// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// One asynchronous change-count read per tick, regardless of subscriber count.
/// Main-thread confined; never waits for the pasteboard server.
final class ClipboardPollingClock {
    static let shared = ClipboardPollingClock { completion in
        GeneralPasteboardAccess.shared.async({ NSPasteboard.general.changeCount }, then: completion)
    }
    private struct Subscription {
        let interval: TimeInterval
        let callback: (Int) -> Void
    }
    private var callbacks: [UUID: Subscription] = [:]
    private var timer: Timer?
    private var order: [UUID] = []
    private var reading = false
    private let readCount: (@escaping (Int) -> Void) -> Void
    private(set) var interval: TimeInterval?

    /// The reader completes on the main thread. Injection keeps tests independent
    /// of the user's clipboard and allows a blocked server to be simulated.
    init(readCount: @escaping (@escaping (Int) -> Void) -> Void) {
        self.readCount = readCount
    }

    func subscribe(interval: TimeInterval = 0.8, _ callback: @escaping (Int) -> Void) -> UUID {
        let id = UUID()
        callbacks[id] = Subscription(interval: max(0.1, interval), callback: callback)
        order.append(id)
        configureTimer()
        return id
    }

    func unsubscribe(_ id: UUID?) {
        guard let id else { return }
        callbacks.removeValue(forKey: id)
        order.removeAll { $0 == id }
        configureTimer()
    }

    private func configureTimer() {
        let next = callbacks.values.map(\.interval).min()
        guard next != interval else { return }
        timer?.invalidate()
        timer = nil
        interval = next
        guard let next else { return }
        let timer = Timer(timeInterval: next, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        guard !reading, !order.isEmpty else { return }
        reading = true
        let recipients = order
        readCount { [weak self] count in
            guard let self else { return }
            self.reading = false
            // New/restarted subscribers must not receive an older observation.
            // Removal by an earlier callback also takes effect immediately.
            for id in recipients { self.callbacks[id]?.callback(count) }
        }
    }

    deinit { timer?.invalidate() }
}
