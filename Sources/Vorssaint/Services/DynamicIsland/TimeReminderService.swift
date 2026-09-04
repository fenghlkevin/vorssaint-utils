import AppKit
import EventKit
import SwiftUI

enum IslandTimePresentation: Equatable {
    case countdown(title: String, remaining: Int, total: Int, paused: Bool)
    case focus(remaining: Int, total: Int)
    case meeting(title: String, start: Date, url: URL?)
    case breakReminder(minutes: Int)
    case completed(title: String, message: String)

    var priority: Int {
        switch self { case .completed: 5; case .meeting: 4; case .breakReminder: 3; case .countdown: 2; case .focus: 1 }
    }
}

final class TimeReminderService: ObservableObject {
    static let shared = TimeReminderService()
    @Published private(set) var presentation: IslandTimePresentation?
    @Published var calendarEnabled: Bool { didSet { UserDefaults.standard.set(calendarEnabled, forKey: "dynamicIsland.calendarEnabled"); if calendarEnabled { requestCalendarAccess() } } }
    @Published var breakEnabled: Bool { didSet { UserDefaults.standard.set(breakEnabled, forKey: "dynamicIsland.breakEnabled") } }
    @Published var breakMinutes: Int { didSet { UserDefaults.standard.set(breakMinutes, forKey: "dynamicIsland.breakMinutes") } }
    @Published var completionDisplaySeconds: Int { didSet { UserDefaults.standard.set(completionDisplaySeconds, forKey: "dynamicIsland.completionSeconds") } }
    @Published var completionSoundEnabled: Bool { didSet { UserDefaults.standard.set(completionSoundEnabled, forKey: "dynamicIsland.completionSoundEnabled") } }
    @Published var completionSoundName: String { didSet { UserDefaults.standard.set(completionSoundName, forKey: "dynamicIsland.completionSoundName") } }
    @Published var completionSoundVolume: Double { didSet { UserDefaults.standard.set(completionSoundVolume, forKey: "dynamicIsland.completionSoundVolume") } }
    @Published private(set) var completionRemainingSeconds = 0

    private enum RunningKind { case countdown, focus }
    private let eventStore = EKEventStore()
    private var runningKind: RunningKind?
    private var title = "倒计时"
    private var endDate: Date?
    private var pausedRemaining: Int?
    private var totalSeconds = 0
    private var lastCalendarCheck = Date.distantPast
    private var workStartedAt = Date()
    private var dismissedMeetingID: String?
    private var breakSnoozedUntil: Date?
    private var completion: IslandTimePresentation?
    private var completionDeadline: Date?

    private init() {
        calendarEnabled = UserDefaults.standard.bool(forKey: "dynamicIsland.calendarEnabled")
        breakEnabled = UserDefaults.standard.bool(forKey: "dynamicIsland.breakEnabled")
        breakMinutes = max(10, UserDefaults.standard.integer(forKey: "dynamicIsland.breakMinutes") == 0 ? 50 : UserDefaults.standard.integer(forKey: "dynamicIsland.breakMinutes"))
        completionDisplaySeconds = max(5, UserDefaults.standard.integer(forKey: "dynamicIsland.completionSeconds") == 0 ? 10 : UserDefaults.standard.integer(forKey: "dynamicIsland.completionSeconds"))
        completionSoundEnabled = UserDefaults.standard.object(forKey: "dynamicIsland.completionSoundEnabled") as? Bool ?? true
        completionSoundName = UserDefaults.standard.string(forKey: "dynamicIsland.completionSoundName") ?? "Glass"
        completionSoundVolume = UserDefaults.standard.object(forKey: "dynamicIsland.completionSoundVolume") as? Double ?? 0.35
    }

    func startCountdown(title: String, minutes: Int) { start(.countdown, title: title.isEmpty ? "倒计时" : title, minutes: minutes) }
    func startFocus(minutes: Int) { start(.focus, title: "专注模式", minutes: minutes) }
    private func start(_ kind: RunningKind, title: String, minutes: Int) {
        runningKind = kind; self.title = title; totalSeconds = max(1, minutes) * 60
        endDate = Date().addingTimeInterval(TimeInterval(totalSeconds)); pausedRemaining = nil; tick()
    }
    func toggleCountdownPause() {
        guard runningKind == .countdown else { return }
        if let remaining = pausedRemaining { endDate = Date().addingTimeInterval(TimeInterval(remaining)); pausedRemaining = nil }
        else { pausedRemaining = remainingSeconds }
        tick()
    }
    func stopTimer() { runningKind = nil; endDate = nil; pausedRemaining = nil; refreshPresentation() }
    func dismissBreak(minutes: Int = 10) { breakSnoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60)); workStartedAt = Date(); refreshPresentation() }
    func startBreak() { breakSnoozedUntil = Date().addingTimeInterval(10 * 60); workStartedAt = Date(); refreshPresentation() }
    func dismissMeeting() { dismissedMeetingID = currentMeeting()?.eventIdentifier; refreshPresentation() }
    func dismissCompletion() { completion = nil; completionDeadline = nil; completionRemainingSeconds = 0; refreshPresentation() }
    var isCompletionPresented: Bool { if case .completed = completion { return true }; return false }
    func joinMeeting() { if case let .meeting(_, _, url) = presentation, let url { NSWorkspace.shared.open(url) } }

    var remainingSeconds: Int {
        if let pausedRemaining { return pausedRemaining }
        return max(0, Int((endDate?.timeIntervalSinceNow ?? 0).rounded(.up)))
    }

    func tick() {
        if let endDate, pausedRemaining == nil, endDate <= Date() {
            let finishedTitle = runningKind == .focus ? "专注结束" : "倒计时结束"
            let finishedMessage = runningKind == .focus ? "本次专注已经完成，可以休息一下了。" : "“\(title)”倒计时已经结束。"
            stopTimer()
            completion = .completed(title: finishedTitle, message: finishedMessage)
            completionDeadline = Date().addingTimeInterval(TimeInterval(completionDisplaySeconds))
            completionRemainingSeconds = completionDisplaySeconds
            if completionSoundEnabled { playCompletionSound() }
            refreshPresentation()
            DynamicIslandService.shared.activateTimeReminder()
        }
        if let completionDeadline {
            completionRemainingSeconds = max(0, Int(completionDeadline.timeIntervalSinceNow.rounded(.up)))
            if Date() >= completionDeadline { dismissCompletion() }
        }
        if Date().timeIntervalSince(lastCalendarCheck) >= 30 { lastCalendarCheck = Date(); refreshPresentation() }
        else { refreshPresentation(includeCalendar: false) }
    }

    func previewCompletionSound() { playCompletionSound() }
    private func playCompletionSound() {
        guard let sound = NSSound(named: NSSound.Name(completionSoundName)) else { return }
        sound.stop(); sound.volume = Float(min(max(completionSoundVolume, 0.05), 1)); sound.play()
    }

    private func refreshPresentation(includeCalendar: Bool = true) {
        let previousPresentation = presentation
        var candidates: [IslandTimePresentation] = []
        if let completion { candidates.append(completion) }
        if includeCalendar || presentation.map({ if case .meeting = $0 { true } else { false } }) == true,
           let event = currentMeeting(), event.eventIdentifier != dismissedMeetingID {
            candidates.append(.meeting(title: event.title ?? "即将开始的日程", start: event.startDate, url: meetingURL(event)))
        }
        if breakEnabled, Date() >= (breakSnoozedUntil ?? .distantPast),
           Date().timeIntervalSince(workStartedAt) >= TimeInterval(breakMinutes * 60) {
            candidates.append(.breakReminder(minutes: breakMinutes))
        }
        if let runningKind {
            let remaining = remainingSeconds
            switch runningKind {
            case .countdown: candidates.append(.countdown(title: title, remaining: remaining, total: totalSeconds, paused: pausedRemaining != nil))
            case .focus: candidates.append(.focus(remaining: remaining, total: totalSeconds))
            }
        }
        let nextPresentation = candidates.max(by: { $0.priority < $1.priority })
        presentation = nextPresentation
        announceIfNeeded(previous: previousPresentation, current: nextPresentation)
    }

    /// Calendar and break alerts use the same user-selected sound and volume
    /// as timer completion. Comparing presentations prevents the one-second
    /// refresh loop from replaying the sound for an alert already on screen.
    private func announceIfNeeded(previous: IslandTimePresentation?,
                                  current: IslandTimePresentation?) {
        guard previous != current else { return }
        switch current {
        case .meeting, .breakReminder:
            if completionSoundEnabled { playCompletionSound() }
            DynamicIslandService.shared.activateTimeReminder()
        default:
            break
        }
    }

    private func requestCalendarAccess() {
        Task { _ = try? await eventStore.requestFullAccessToEvents(); await MainActor.run { self.refreshPresentation() } }
    }
    private func currentMeeting() -> EKEvent? {
        guard calendarEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let now = Date(), end = now.addingTimeInterval(10 * 60)
        return eventStore.events(matching: eventStore.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }.first
    }
    private func meetingURL(_ event: EKEvent) -> URL? {
        if let url = event.url { return url }
        let text = [event.notes, event.location].compactMap { $0 }.joined(separator: " ")
        return text.split(whereSeparator: { $0.isWhitespace }).compactMap { URL(string: String($0)) }.first(where: { $0.scheme?.hasPrefix("http") == true })
    }
}
