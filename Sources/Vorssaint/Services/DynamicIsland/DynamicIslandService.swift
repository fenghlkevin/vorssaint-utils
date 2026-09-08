import AppKit
import SwiftUI

private final class DynamicIslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class KeyableDynamicIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class DynamicIslandService: ObservableObject {
    static let shared = DynamicIslandService()
    var expandedSize: NSSize {
        // Every tab shares the calendar design's canvas. Switching content
        // must never resize the AppKit window: that causes the lower edge to
        // jump and makes the tab animation appear to stutter.
        NSSize(width: 780 * expandedScale, height: 310 * expandedScale)
    }
    @Published private(set) var expandedScale: CGFloat = 1
    @Published private(set) var usesLaptopLayout = false
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: DefaultsKey.dynamicIslandEnabled); syncWithPreferences() } }
    @Published var selectedDisplay: String { didSet { UserDefaults.standard.set(selectedDisplay, forKey: DefaultsKey.dynamicIslandDisplay); rebuild() } }
    @Published var showAIHookTab: Bool { didSet { UserDefaults.standard.set(showAIHookTab, forKey: "dynamicIsland.showAIHookTab") } }
    @Published var showMusicTab: Bool { didSet { UserDefaults.standard.set(showMusicTab, forKey: "dynamicIsland.showMusicTab") } }
    @Published var showTimerTab: Bool { didSet { UserDefaults.standard.set(showTimerTab, forKey: "dynamicIsland.showTimerTab") } }
    @Published var showMemoTab: Bool { didSet { UserDefaults.standard.set(showMemoTab, forKey: "dynamicIsland.showMemoTab") } }
    @Published var nowPlaying: RadialNowPlayingSnapshot?
    @Published var isPlaying = false
    @Published var elapsedTime = 0.0
    @Published var duration = 0.0
    @Published var outputVolume = 0.5
    @Published private(set) var musicLaunchInProgress = false
    @Published private(set) var expanded = false
    @Published private(set) var showsExpandedContent = false
    @Published private(set) var compactWidth = 230.0
    @Published private(set) var compactHeight = 34.0
    @Published private(set) var hasDisplayNotch = false
    @Published private(set) var displayNotchWidth = 0.0
    @Published private(set) var isIdleCompact = false
    @Published private(set) var timeReminderActivationID = UUID()
    @Published private(set) var codexActivationID = UUID()
    @Published private(set) var codexTabActive = true
    @Published private(set) var expandedCanvas = "codex"
    private var window: NSWindow?
    private var monitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var refreshTimer: Timer?
    private var hoverTimer: Timer?
    @Published private(set) var presentationSuspended = false
    private var screenSleeping = false
    private var sessionLocked = false
    private var powerObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastSuspendedLogRefresh = Date.distantPast
    private var pendingCodexAttention = false
    private var pendingTimeAttention = false

    private let playerQueryQueue = DispatchQueue(label: "com.vorssaint.dynamic-island.player-query",
                                                  qos: .utility)
    private var playerQueryInFlight = false
    private var cachedArtworkKey: String?
    private var cachedArtworkData: Data?
    private var collapseWorkItem: DispatchWorkItem?
    private var musicLaunchTimeoutWorkItem: DispatchWorkItem?
    private var codexAttentionDeadline: Date?
    private var activeDisplayNumber: NSNumber?
    private var primaryButtonWasDown = false
    private init() {
        enabled = UserDefaults.standard.object(forKey: DefaultsKey.dynamicIslandEnabled) as? Bool ?? true
        selectedDisplay = UserDefaults.standard.string(forKey: DefaultsKey.dynamicIslandDisplay) ?? "active"
        showAIHookTab = UserDefaults.standard.object(forKey: "dynamicIsland.showAIHookTab") as? Bool ?? true
        showMusicTab = UserDefaults.standard.object(forKey: "dynamicIsland.showMusicTab") as? Bool ?? true
        showTimerTab = UserDefaults.standard.object(forKey: "dynamicIsland.showTimerTab") as? Bool ?? true
        showMemoTab = UserDefaults.standard.object(forKey: "dynamicIsland.showMemoTab") as? Bool ?? true
        activeDisplayNumber = Self.screen(at: NSEvent.mouseLocation)?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
    var visibleTabCount: Int {
        [showAIHookTab, showMusicTab, showTimerTab, showMemoTab].filter { $0 }.count
    }
    func syncWithPreferences() {
        guard AppFeature.dynamicIsland.isAvailable, enabled else { stop(); return }
        start()
    }
    func start() {
        guard enabled, refreshTimer == nil else { return }
        CodexIslandService.shared.syncHookInstallation()
        installPowerObservers()
        show(); refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            TimeReminderService.shared.tick()
            if presentationSuspended {
                let readLogs = Date().timeIntervalSince(lastSuspendedLogRefresh) >= 15
                if readLogs { lastSuspendedLogRefresh = Date() }
                CodexIslandService.shared.refresh(includeSessionLogs: readLogs)
            } else { refresh(); show() }
        }
        refreshTimer?.tolerance = 0.15
        startHoverTimer()
        monitor = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.handlePointerClick(at: NSEvent.mouseLocation) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handlePointerClick(at: NSEvent.mouseLocation)
            return event
        }
    }
    private func startHoverTimer() {
        guard !presentationSuspended, hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateHoverState()
        }
        hoverTimer?.tolerance = 0.02
    }

    private func installPowerObservers() {
        guard powerObservers.isEmpty else { return }
        sessionLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
            powerObservers.append((center, token))
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.sessionLocked = true; self?.syncPresentationSuspension()
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.sessionLocked = false; self?.syncPresentationSuspension()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.screenSleeping = true; self?.syncPresentationSuspension()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.screenSleeping = false; self?.syncPresentationSuspension()
        }
        syncPresentationSuspension()
    }

    private func syncPresentationSuspension() {
        let suspended = sessionLocked || screenSleeping
        guard presentationSuspended != suspended else { return }
        presentationSuspended = suspended
        if suspended {
            hoverTimer?.invalidate(); hoverTimer = nil
            collapseWorkItem?.cancel(); collapseWorkItem = nil
            hide()
        } else if enabled {
            startHoverTimer()
            refresh(); show()
            if pendingCodexAttention { pendingCodexAttention = false; activateCodex() }
            if pendingTimeAttention {
                pendingTimeAttention = false
                if TimeReminderService.shared.presentation != nil { activateTimeReminder() }
            }
        }
    }

    func stop() {
        for (center, token) in powerObservers { center.removeObserver(token) }
        powerObservers.removeAll()
        pendingCodexAttention = false; pendingTimeAttention = false
        screenSleeping = false; sessionLocked = false
        if !presentationSuspended { presentationSuspended = true }
        if let monitor { NotificationCenter.default.removeObserver(monitor) }; monitor = nil; if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }; globalClickMonitor = nil; if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }; localClickMonitor = nil; refreshTimer?.invalidate(); refreshTimer = nil; hoverTimer?.invalidate(); hoverTimer = nil; musicLaunchTimeoutWorkItem?.cancel(); musicLaunchTimeoutWorkItem = nil; musicLaunchInProgress = false; hide() }
    private var targetScreen: NSScreen? {
        if selectedDisplay == "active" {
            if let activeDisplayNumber,
               let screen = NSScreen.screens.first(where: {
                   ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == activeDisplayNumber
               }) { return screen }
            if let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen { return screen }
            let point = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(point) }
                ?? NSScreen.main ?? NSScreen.screens.first
        }
        return NSScreen.screens.first { $0.localizedName == selectedDisplay }
    }

    private static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func frontmostApplicationScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for row in rows {
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 80, frame.height > 80 else { continue }
            if let screen = NSScreen.screens.max(by: {
                $0.frame.intersection(frame).width * $0.frame.intersection(frame).height
                    < $1.frame.intersection(frame).width * $1.frame.intersection(frame).height
            }), screen.frame.intersects(frame) {
                return screen
            }
        }
        return nil
    }
    private func show(animated: Bool = false) {
        guard enabled, !presentationSuspended, let screen = targetScreen else { return }
        if window == nil {
            let w = KeyableDynamicIslandPanel(contentRect: .zero,
                                               styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered,
                                               defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.level = .statusBar; w.hasShadow = false
            w.acceptsMouseMovedEvents = true
            w.becomesKeyOnlyIfNeeded = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = DynamicIslandHostingView(rootView: DynamicIslandView())
            window = w
        }
        let visible = screen.frame
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let isBuiltInDisplay = displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        if usesLaptopLayout != isBuiltInDisplay { usesLaptopLayout = isBuiltInDisplay }
        let nextExpandedScale: CGFloat = isBuiltInDisplay ? 0.84 : 1
        if expandedScale != nextExpandedScale { expandedScale = nextExpandedScale }
        let hasNotch = screen.safeAreaInsets.top > 0
        let notchWidth: CGFloat = {
            guard hasNotch,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else { return 0 }
            return max(0, right.minX - left.maxX)
        }()
        if hasDisplayNotch != hasNotch { hasDisplayNotch = hasNotch }
        if displayNotchWidth != notchWidth { displayNotchWidth = notchWidth }
        let codexIsActive = CodexIslandService.shared.sessions.contains {
            $0.status == .running || $0.status == .waiting
        }
        let hasLiveActivity = isPlaying || codexIsActive
            || TimeReminderService.shared.presentation != nil
        let nextIdleCompact = !hasNotch && !hasLiveActivity
        if isIdleCompact != nextIdleCompact { isIdleCompact = nextIdleCompact }
        let preferredCompactWidth: CGFloat = CodexIslandService.shared.enabled ? 270 : 230
        let nextCompactWidth = nextIdleCompact
            ? 96
            : (hasNotch ? (isBuiltInDisplay ? notchWidth + 60 : max(preferredCompactWidth, notchWidth + 244)) : (isBuiltInDisplay ? 190 : preferredCompactWidth))
        if compactWidth != nextCompactWidth { compactWidth = nextCompactWidth }
        // On the built-in display, align the bottom with the physical notch.
        // The side wings and expanded hover hit region still allow activation.
        let nextCompactHeight = nextIdleCompact
            ? 10
            : (hasNotch ? screen.safeAreaInsets.top + (isBuiltInDisplay ? 0 : 8) : 28)
        if compactHeight != nextCompactHeight { compactHeight = nextCompactHeight }
        let size = expandedSize
        let frame = NSRect(x: visible.midX - size.width / 2,
                           y: visible.maxY - size.height,
                           width: size.width,
                           height: size.height)
        if animated, window?.frame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window?.animator().setFrame(frame, display: true)
            }
        } else if window?.frame != frame {
            window?.setFrame(frame, display: true)
        }
        if window?.ignoresMouseEvents != !expanded { window?.ignoresMouseEvents = !expanded }
        if window?.isVisible == false { window?.orderFrontRegardless() }
    }
    private func hide() { window?.orderOut(nil) }
    private func rebuild() { guard enabled else { return }; hide(); show() }
    private func refresh() {
        guard enabled, !presentationSuspended else { return }
        CodexIslandService.shared.refresh()
        RadialNowPlayingService.shared.refresh { [weak self] state in
            guard let self else { return }
            switch state {
            case let .playing(snapshot):
                publish(snapshot)
            case .nothingPlaying:
                refreshAppleMusicFallback()
            case .loading:
                // `refresh` reports loading synchronously before the real
                // callback. Keep the last good card on screen during that gap.
                break
            }
        }
    }

    private func publish(_ snapshot: RadialNowPlayingSnapshot?) {
        guard enabled, !presentationSuspended else { return }
        if nowPlaying != snapshot { nowPlaying = snapshot }
        if snapshot != nil {
            musicLaunchTimeoutWorkItem?.cancel()
            musicLaunchTimeoutWorkItem = nil
            if musicLaunchInProgress { musicLaunchInProgress = false }
        }
        let nextPlaying = snapshot?.isPlaying ?? false
        let nextElapsed = snapshot?.elapsedTime ?? 0
        let nextDuration = snapshot?.duration ?? 0
        let nextVolume = AppVolumeMixer.systemOutputVolumeLevel() ?? outputVolume
        if isPlaying != nextPlaying { isPlaying = nextPlaying }
        if elapsedTime != nextElapsed { elapsedTime = nextElapsed }
        if duration != nextDuration { duration = nextDuration }
        if outputVolume != nextVolume { outputVolume = nextVolume }
        show()
    }

    /// MediaRemote returns nil on some recent macOS builds even while Music is
    /// visibly playing. Query Music only as a fallback; other players still use
    /// the system-wide route above.
    private func refreshAppleMusicFallback() {
        guard enabled, !presentationSuspended else { return }
        guard !playerQueryInFlight else { return }
        guard NSWorkspace.shared.runningApplications.contains(where: {
                  $0.bundleIdentifier == "com.apple.Music"
              }) else {
            publish(nil)
            return
        }
        playerQueryInFlight = true
        playerQueryQueue.async { [weak self] in
            guard let self else { return }
            let script = """
            tell application "Music"
                if player state is stopped then return ""
                set currentItem to current track
                return (name of currentItem as text) & (character id 31) & (artist of currentItem as text) & (character id 31) & (album of currentItem as text) & (character id 31) & (player state as text) & (character id 31) & (player position as text) & (character id 31) & (duration of currentItem as text)
            end tell
            """
            let result = AppleScriptRunner.runDetailed(script)
            let fields = result.output.components(separatedBy: String(UnicodeScalar(31)!))
            let artworkKey = fields.prefix(3).joined(separator: String(UnicodeScalar(31)!))
            if result.ok, !result.output.isEmpty, artworkKey != self.cachedArtworkKey {
                self.cachedArtworkKey = artworkKey
                self.cachedArtworkData = self.readAppleMusicArtwork()
            }
            let snapshot: RadialNowPlayingSnapshot? = result.ok && !result.output.isEmpty
                ? RadialNowPlayingSnapshot(title: fields.indices.contains(0) ? fields[0] : nil,
                                           artist: fields.indices.contains(1) ? fields[1] : nil,
                                           album: fields.indices.contains(2) ? fields[2] : nil,
                                           artworkData: self.cachedArtworkData,
                                           appBundleIdentifier: "com.apple.Music",
                                           appPID: nil,
                                           isPlaying: fields.indices.contains(3) && fields[3] == "playing",
                                           elapsedTime: fields.indices.contains(4) ? Double(fields[4]) : nil,
                                           duration: fields.indices.contains(5) ? Double(fields[5]) : nil)
                : nil
            DispatchQueue.main.async {
                self.playerQueryInFlight = false
                self.publish(snapshot)
            }
        }
    }

    private func readAppleMusicArtwork() -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-current-music-artwork")
        let path = AppleScriptRunner.literal(url.path)
        let script = """
        tell application "Music"
            if (count of artworks of current track) is 0 then return ""
            set artworkData to data of artwork 1 of current track
            set outputFile to open for access POSIX file \(path) with write permission
            set eof outputFile to 0
            write artworkData to outputFile
            close access outputFile
            return "ok"
        end tell
        """
        let result = AppleScriptRunner.runDetailed(script)
        guard result.ok, result.output == "ok",
              let data = try? Data(contentsOf: url), !data.isEmpty,
              NSImage(data: data) != nil else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    func togglePlayback() {
        if nowPlaying == nil { launchAndPlayMusic() }
        else if nowPlaying?.appBundleIdentifier == "com.apple.Music" { runMusicCommand("playpause") }
        else { Self.sendMediaKey(16) }
    }

    private func launchAndPlayMusic() {
        guard !musicLaunchInProgress else { return }
        musicLaunchInProgress = true
        show()
        if !expanded { setExpanded(true) }
        musicLaunchTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.musicLaunchInProgress = false }
        musicLaunchTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        // The first `play` sent while Music is cold-launching is frequently
        // discarded. Launch once, then retry the idempotent `play` command
        // until the player reports that it accepted it.
        playerQueryQueue.async { [weak self] in
            let script = """
            tell application "Music" to activate
            repeat 16 times
                delay 0.35
                try
                    tell application "Music"
                        play
                        if player state is playing then return "playing"
                    end tell
                end try
            end repeat
            return "timeout"
            """
            _ = AppleScriptRunner.runDetailed(script)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func seek(to value: Double) {
        elapsedTime = value
        guard nowPlaying?.appBundleIdentifier == "com.apple.Music" else { return }
        runMusicCommand("set player position to \(value)")
    }

    func setVolume(_ value: Double) {
        outputVolume = value
        _ = AppVolumeMixer.setSystemOutputVolume(value)
    }

    func toggleMusicShuffle() {
        runMusicCommand("set shuffle enabled to not shuffle enabled")
    }

    func cycleMusicRepeat() {
        playerQueryQueue.async { [weak self] in
            let script = """
            tell application "Music"
                if song repeat is off then
                    set song repeat to all
                else if song repeat is all then
                    set song repeat to one
                else
                    set song repeat to off
                end if
            end tell
            """
            _ = AppleScriptRunner.runDetailed(script)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func openMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func activateTimeReminder() {
        guard !presentationSuspended else { pendingTimeAttention = true; return }
        timeReminderActivationID = UUID()
        show()
        if !expanded { setExpanded(true) }
    }

    func activateCodex(duration: TimeInterval = 5) {
        guard !presentationSuspended else { pendingCodexAttention = true; return }
        codexActivationID = UUID()
        codexAttentionDeadline = Date().addingTimeInterval(duration)
        show()
        if !expanded { setExpanded(true) }
    }

    func setCodexTabActive(_ active: Bool) {
        guard codexTabActive != active else { return }
        codexTabActive = active
    }

    func setExpandedCanvas(_ value: String) {
        guard expandedCanvas != value else { return }
        expandedCanvas = value
    }

    func setExpanded(_ value: Bool) {
        if value {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            guard !expanded else { return }
            transition(toExpanded: true)
            return
        }
        guard expanded, collapseWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.expanded else { return }
            self.collapseWorkItem = nil
            self.transition(toExpanded: false)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
    }

    private func transition(toExpanded value: Bool) {
        guard window != nil else { return }
        // Size and content used to begin at different times, producing a
        // visible pause and a second jump halfway through each transition.
        // Drive both from one transaction so SwiftUI interpolates one shape.
        withAnimation(.smooth(duration: value ? 0.46 : 0.40)) {
            expanded = value
            showsExpandedContent = value
        }
        show()
    }

    private func updateHoverState() {
        updateActiveDisplayFromMouseClick()
        guard let window, window.isVisible else { return }
        if window.isKeyWindow { return }
        if case .completed = TimeReminderService.shared.presentation {
            if !expanded { activateTimeReminder() }
            return
        }
        if musicLaunchInProgress {
            if !expanded { setExpanded(true) }
            return
        }
        if let deadline = codexAttentionDeadline, deadline > Date() {
            if !expanded { setExpanded(true) }
            return
        }
        let hitSize = expanded
            ? expandedSize
            : NSSize(width: compactWidth, height: compactHeight)
        let baseHitFrame = NSRect(x: window.frame.midX - hitSize.width / 2,
                                  y: window.frame.maxY - hitSize.height,
                                  width: hitSize.width,
                                  height: hitSize.height)
        // NSRect.contains excludes its maximum edge. The pointer can report
        // exactly screen.frame.maxY when pushed against the menu-bar edge, so
        // use a larger exit region and explicitly include that top boundary.
        let hitFrame = baseHitFrame.insetBy(dx: expanded ? -16 : -5,
                                            dy: expanded ? -12 : -5)
        let point = NSEvent.mouseLocation
        let mouseInside = point.x >= hitFrame.minX && point.x <= hitFrame.maxX
            && point.y >= hitFrame.minY && point.y <= hitFrame.maxY
        // Re-entry must cancel a pending collapse even while already open.
        // Allow SwiftUI to retarget an in-flight animation from its current
        // presentation instead of dropping pointer input until it finishes.
        setExpanded(mouseInside)
    }


    private func updateActiveDisplayFromMouseClick() {
        let isDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        defer { primaryButtonWasDown = isDown }
        guard isDown, !primaryButtonWasDown else { return }
        activateDisplay(at: NSEvent.mouseLocation)
    }

    private func activateDisplay(at point: CGPoint) {
        guard let screen = Self.screen(at: point),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              number != activeDisplayNumber else { return }
        activeDisplayNumber = number
        if selectedDisplay == "active" { show() }
    }

    private func handlePointerClick(at point: CGPoint) {
        if TimeReminderService.shared.isCompletionPresented {
            TimeReminderService.shared.dismissCompletion()
        }
        activateDisplay(at: point)
    }

    private func runMusicCommand(_ command: String) {
        playerQueryQueue.async {
            _ = AppleScriptRunner.runDetailed("tell application \"Music\" to \(command)")
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }
}

struct CodexActivityIndicator: View {
    @ObservedObject private var island = DynamicIslandService.shared
    let status: CodexIslandSession.Status?

    var body: some View {
        if status == .running {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: island.presentationSuspended)) { timeline in
                pulseIndicator(phase: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.25) / 1.25)
            }
        } else {
            pulseIndicator(phase: 0.5)
        }
    }

    private func pulseIndicator(phase: Double) -> some View {
        Canvas { context, size in
            let points: [CGPoint] = [
                CGPoint(x: 0.02, y: 0.55), CGPoint(x: 0.20, y: 0.55),
                CGPoint(x: 0.29, y: 0.40), CGPoint(x: 0.38, y: 0.69),
                CGPoint(x: 0.49, y: 0.10), CGPoint(x: 0.61, y: 0.87),
                CGPoint(x: 0.72, y: 0.47), CGPoint(x: 0.81, y: 0.55),
                CGPoint(x: 0.98, y: 0.55)
            ].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

            var base = Path()
            base.move(to: points[0])
            for point in points.dropFirst() { base.addLine(to: point) }
            context.stroke(base, with: .color(color.opacity(0.48)),
                           style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))

            for index in 0..<(points.count - 1) {
                let position = (Double(index) + 0.5) / Double(points.count - 1)
                let distance = abs(position - phase)
                let wrappedDistance = min(distance, 1 - distance)
                let intensity = max(0, 1 - wrappedDistance / 0.22)
                guard intensity > 0 else { continue }
                var segment = Path()
                segment.move(to: points[index])
                segment.addLine(to: points[index + 1])
                context.stroke(segment, with: .color(color.opacity(0.52 + intensity * 0.48)),
                               style: StrokeStyle(lineWidth: 1.7 + intensity * 0.45,
                                                  lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 25, height: 20)
        .shadow(color: color.opacity(status == .running ? 0.62 : 0.25), radius: 2.5)
    }

    private var color: Color {
        switch status {
        case .waiting: return .orange
        case .completed: return Color(red: 0.15, green: 0.92, blue: 0.43)
        case .failed: return .red
        default: return Color(red: 0.20, green: 0.57, blue: 1)
        }
    }
}

private struct DynamicIslandView: View {
    private enum IslandTab: Equatable { case codex, music, time, memo }
    private enum TimerMode { case countdown, focus, rest }
    @ObservedObject private var island = DynamicIslandService.shared
    @ObservedObject private var reminders = TimeReminderService.shared
    @ObservedObject private var codex = CodexIslandService.shared
    @ObservedObject private var islandMemos = IslandMemoService.shared
    @State private var selectedTab: IslandTab = .codex
    @State private var quickMinutes = 25
    @State private var memoText = ""
    @State private var memoPage = 0
    @State private var timerMode: TimerMode = .focus
    @State private var selectedCalendarDate = Date()
    @FocusState private var memoFocused: Bool
    var body: some View {
        Group {
            if island.showsExpandedContent, selectedTab == .time {
                Group {
                    if let reminder = reminders.presentation { reminderContent(reminder) }
                    else { timeSetupContent }
                }
                    .transition(.opacity)
            } else if island.showsExpandedContent, selectedTab == .music {
                expandedContent
                    .transition(.opacity)
            } else if island.showsExpandedContent, selectedTab == .memo {
                memoContent.transition(.opacity)
            } else if island.showsExpandedContent {
                codexContent
                    .transition(.opacity)
            } else if island.isIdleCompact {
                Color.clear
            } else {
                compactContent
                    .transition(.opacity)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        // Content leaves quickly while the outer shell continues shrinking.
        // Keep this animation inside the size modifier so it cannot shorten
        // the shell's smooth, interruptible transition.
        .animation(.easeOut(duration: island.showsExpandedContent ? 0.18 : 0.10),
                   value: island.showsExpandedContent)
        .frame(width: island.expanded ? 780 : island.compactWidth,
               height: island.expanded ? 310 : island.compactHeight)
        .background(Color.black, in: UnevenRoundedRectangle(topLeadingRadius: 0,
                                                            bottomLeadingRadius: 8,
                                                            bottomTrailingRadius: 8,
                                                            topTrailingRadius: 0,
                                                            style: .continuous))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0,
                                         bottomLeadingRadius: 8,
                                         bottomTrailingRadius: 8,
                                         topTrailingRadius: 0,
                                         style: .continuous))
        .overlay(alignment: .topTrailing) {
            if island.showsExpandedContent {
                modeSwitcher.transition(.opacity.animation(.easeOut(duration: 0.10)))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: selectedTab)
        .onAppear { ensureSelectedTabIsVisible() }
        .onChange(of: visibleTabsSignature) { _, _ in ensureSelectedTabIsVisible() }
        .onChange(of: reminders.presentation) { oldValue, newValue in
            if oldValue == nil, newValue != nil, island.showTimerTab { selectedTab = .time }
            if newValue == nil, island.showAIHookTab { selectedTab = .codex }
        }
        .onChange(of: island.timeReminderActivationID) { _, _ in
            if island.showTimerTab { selectedTab = .time }
        }
        .onChange(of: island.codexActivationID) { _, _ in
            if island.showAIHookTab { selectedTab = .codex }
        }
        .onChange(of: selectedTab) { _, value in
            island.setCodexTabActive(value == .codex)
            island.setExpandedCanvas(value == .time ? "time" : "codex")
        }
        .scaleEffect(island.expanded ? island.expandedScale : 1, anchor: .top)
        .frame(width: island.expanded ? island.expandedSize.width : island.compactWidth,
               height: island.expanded ? island.expandedSize.height : island.compactHeight,
               alignment: .top)
        // The hosting window retains the expanded canvas when collapsed.
        // Fill it only AFTER sizing the island, so AppKit cannot stretch the
        // root's compact frame or anchor it at the window's leading edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            Spacer()
            if island.showAIHookTab {
                Button { selectedTab = .codex } label: {
                    Label("AI Hook", systemImage: "terminal.fill").labelStyle(.iconOnly)
                        .foregroundStyle(.white)
                        .font(.system(size: 11)).frame(width: 25, height: 22).background(selectedTab == .codex ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if island.showMusicTab {
                Button { selectedTab = .music } label: {
                    Label("音乐", systemImage: "music.note").labelStyle(.iconOnly)
                        .foregroundStyle(.white)
                        .font(.system(size: 11)).frame(width: 25, height: 22).background(selectedTab == .music ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if island.showTimerTab {
                Button { selectedTab = .time } label: {
                    Label("定时器", systemImage: "timer").labelStyle(.iconOnly)
                        .foregroundStyle(.white)
                        .font(.system(size: 11)).frame(width: 25, height: 22).background(selectedTab == .time ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if island.showMemoTab {
                Button { selectedTab = .memo } label: {
                    Label("备忘", systemImage: "square.and.pencil").labelStyle(.iconOnly)
                        .foregroundStyle(.white)
                        .font(.system(size: 11)).frame(width: 25, height: 22).background(selectedTab == .memo ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }.padding(.top, 6).padding(.trailing, 10)
    }

    private var visibleTabsSignature: String {
        "\(island.showAIHookTab)-\(island.showMusicTab)-\(island.showTimerTab)-\(island.showMemoTab)"
    }

    private func isVisible(_ tab: IslandTab) -> Bool {
        switch tab {
        case .codex: return island.showAIHookTab
        case .music: return island.showMusicTab
        case .time: return island.showTimerTab
        case .memo: return island.showMemoTab
        }
    }

    private func ensureSelectedTabIsVisible() {
        guard !isVisible(selectedTab) else { return }
        if island.showAIHookTab { selectedTab = .codex }
        else if island.showMusicTab { selectedTab = .music }
        else if island.showTimerTab { selectedTab = .time }
        else if island.showMemoTab { selectedTab = .memo }
    }

    private var timeSetupContent: some View {
        HStack(alignment: .top, spacing: 12) {
            focusTimerCard
                .frame(width: 365)
            calendarCard
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 12)
    }

    private var focusTimerCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("专注当下").font(.system(size: 17, weight: .bold))
                    Text("更好的自己，从专注开始").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Label(timerMode == .rest ? "放松片刻" : "保持专注 · 高效生活", systemImage: "leaf.fill")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .padding(.horizontal, 10).frame(height: 25)
                    .background(.white.opacity(0.06), in: Capsule())
            }
            HStack(spacing: 20) {
                Button { quickMinutes = max(1, quickMinutes - 1) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .accessibilityLabel("减少一分钟")
                ZStack {
                    Circle().stroke(.white.opacity(0.10), lineWidth: 9)
                    Circle().trim(from: 0, to: min(Double(quickMinutes) / 60, 1))
                        .stroke(.orange, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 4) {
                        Text(String(format: "%02d:00", quickMinutes))
                            .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(timerMode == .rest ? "休息时间" : "专注进行中")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(width: 112, height: 112)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { updateMinutes(from: $0.location, size: 112) })
                .accessibilityLabel("拖动调整倒计时分钟")
                .accessibilityValue("\(quickMinutes) 分钟")
                Button { quickMinutes = min(240, quickMinutes + 1) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .accessibilityLabel("增加一分钟")
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                timerModeButton(.focus, title: "专注", symbol: "scope")
                timerModeButton(.rest, title: "休息", symbol: "cup.and.saucer.fill")
            Button { startSelectedTimer() } label: {
                Label("开始", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
            }.buttonStyle(.plain).background(.orange, in: Capsule())
                .accessibilityLabel(timerMode == .rest ? "开始休息" : "开始专注")
            }
            HStack {
                Image(systemName: "quote.opening")
                Text("专注不是排除干扰，而是选择重要的事。")
                Spacer()
                Image(systemName: "quote.closing")
            }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.42))
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))
    }

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(calendarHeading).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { shiftSelectedDate(days: -7) } label: { Image(systemName: "chevron.left") }
                Button { selectedCalendarDate = Date() } label: { Text("今天") }
                    .font(.system(size: 9, weight: .medium))
                Button { shiftSelectedDate(days: 7) } label: { Image(systemName: "chevron.right") }
            }.foregroundStyle(.white.opacity(0.75))
            weekStrip
                .padding(6)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            VStack(spacing: 6) {
                HStack {
                    Label("当天日程", systemImage: "calendar").font(.system(size: 10, weight: .semibold))
                    Spacer()
                }.foregroundStyle(.orange)
                if selectedDateEvents.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "doc.text").font(.system(size: 19)).foregroundStyle(.white.opacity(0.4))
                        Text(reminders.calendarEnabled ? "当天暂无日程" : "开启日历后显示日程")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(selectedDateEvents) { event in calendarEventRow(event) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))
    }

    private var weekStrip: some View {
        let calendar = Calendar.current
        let today = selectedCalendarDate
        let weekday = calendar.component(.weekday, from: today)
        let mondayOffset = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -mondayOffset, to: today) ?? today
        return HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: monday) ?? today
                let isSelected = calendar.isDate(date, inSameDayAs: selectedCalendarDate)
                VStack(spacing: 4) {
                    Text(["一", "二", "三", "四", "五", "六", "日"][offset])
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.42))
                    Text("\(calendar.component(.day, from: date))")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 24)
                        .background(isSelected ? Color.orange : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedCalendarDate = date }
            }
        }
    }

    private var selectedDateEvents: [IslandCalendarEvent] {
        Calendar.current.isDateInToday(selectedCalendarDate)
            ? reminders.todayEvents : reminders.calendarEvents(on: selectedCalendarDate)
    }

    private var calendarHeading: String {
        let prefix = Calendar.current.isDateInToday(selectedCalendarDate) ? "今天" : selectedCalendarDate.formatted(.dateTime.weekday(.wide))
        return "\(prefix) · \(selectedCalendarDate.formatted(.dateTime.month().day()))"
    }

    private func shiftSelectedDate(days: Int) {
        selectedCalendarDate = Calendar.current.date(byAdding: .day, value: days, to: selectedCalendarDate) ?? selectedCalendarDate
    }

    private func startSelectedTimer() {
        if timerMode == .focus { reminders.startFocus(minutes: quickMinutes) }
        else if timerMode == .rest { reminders.startCountdown(title: "休息", minutes: quickMinutes) }
        else { reminders.startCountdown(title: "倒计时", minutes: quickMinutes) }
    }

    private func timerModeButton(_ mode: TimerMode, title: String, symbol: String) -> some View {
        let selected = timerMode == mode
        return Button {
            timerMode = mode
            if mode == .rest { quickMinutes = 10 }
            if mode == .focus, quickMinutes == 10 { quickMinutes = 25 }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                .background(selected ? Color.orange.opacity(0.9) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func updateMinutes(from location: CGPoint, size: CGFloat) {
        let center = CGPoint(x: size / 2, y: size / 2)
        let angle = atan2(location.x - center.x, center.y - location.y)
        let normalized = angle < 0 ? angle + 2 * .pi : angle
        let minute = Int((normalized / (2 * .pi) * 60).rounded())
        quickMinutes = minute == 0 ? 60 : min(max(minute, 1), 60)
    }

    private func calendarEventRow(_ event: IslandCalendarEvent) -> some View {
        HStack(spacing: 9) {
            Text(event.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().frame(width: 42, alignment: .leading)
            Capsule().fill(event.provider == nil ? Color.white.opacity(0.3) : .blue).frame(width: 2, height: 22)
            Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let provider = event.provider {
                Text(provider == .tencent ? "腾讯会议" : "钉钉会议")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.blue)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                Button("加入") { reminders.join(event) }
                    .font(.system(size: 10, weight: .medium)).buttonStyle(.bordered)
            } else if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
        }
        .padding(.horizontal, 9).frame(height: 35)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private var nextMeetingFooter: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock").foregroundStyle(.orange)
            if let meeting = reminders.nextJoinableMeeting {
                Text("下一场会议还有").foregroundStyle(.white.opacity(0.6))
                Text(nextMeetingDistance(meeting.start)).foregroundStyle(.orange).fontWeight(.semibold)
            } else {
                Text("今天没有待加入的线上会议").foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: "calendar.badge.gearshape").foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 11)).padding(.horizontal, 14).frame(height: 32)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07)))
    }

    private func nextMeetingDistance(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds < 60 { return "不到 1 分钟" }
        return "\((seconds + 59) / 60) 分钟"
    }

    private var compactContent: some View {
        Group {
            if island.hasDisplayNotch {
                notchCompactContent
            } else {
                regularCompactContent
            }
        }
    }

    private var notchCompactContent: some View {
        HStack(spacing: 0) {
            if island.usesLaptopLayout {
                Group {
                    if reminders.presentation != nil || !codex.enabled {
                        Image(systemName: compactSymbol).font(.system(size: 13))
                    } else {
                        CodexActivityIndicator(status: codex.activeSession?.status)
                    }
                }.frame(width: 30)

                Color.clear.frame(width: island.displayNotchWidth)

                Group {
                    if let reminder = reminders.presentation {
                        Text(compactTitle(reminder)).lineLimit(1)
                    } else if codex.enabled {
                        Text("\(codex.sessions.count)").monospacedDigit()
                    } else {
                        compactTrailingContent
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .frame(width: 30)
            } else {
            compactLeadingContent
                .frame(width: 154, alignment: .leading)
                .padding(.leading, 10)

            Color.clear
                .frame(width: island.displayNotchWidth)

            compactTrailingContent
                .frame(width: 70, alignment: .trailing)
                .padding(.trailing, 10)
            }
        }
    }

    private var regularCompactContent: some View {
        HStack(spacing: 8) {
            if reminders.presentation != nil || !codex.enabled {
                Image(systemName: compactSymbol).font(.caption)
            }
            if let reminder = reminders.presentation {
                Text(compactTitle(reminder))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
            } else if codex.enabled {
                CodexActivityIndicator(status: codex.activeSession?.status)
                Text(compactCodexTitle).font(.custom("Departure Mono", size: 11).weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(codexCompactSummary)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.62))
            } else if let track = island.nowPlaying {
                Text(track.title ?? "正在播放")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Button(action: { island.togglePlayback() }) {
                    Image(systemName: island.isPlaying ? "pause.fill" : "play.fill")
                }
            } else {
                Text("Apple Music").font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                Button(action: { island.togglePlayback() }) {
                    if island.musicLaunchInProgress {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private var codexCompactSummary: String {
        var values: [String] = []
        if codex.runningCount > 0 { values.append("\(codex.runningCount) 运行") }
        if codex.waitingCount > 0 { values.append("\(codex.waitingCount) 等待") }
        return values.isEmpty ? "\(codex.sessions.count) 个会话" : values.joined(separator: " · ")
    }

    @ViewBuilder private var compactLeadingContent: some View {
        HStack(spacing: 7) {
            if reminders.presentation != nil || !codex.enabled {
                Image(systemName: compactSymbol).font(.caption)
            }
            if let reminder = reminders.presentation {
                Text(compactTitle(reminder)).font(.caption.weight(.semibold)).lineLimit(1)
            } else if codex.enabled {
                CodexActivityIndicator(status: codex.activeSession?.status)
                Text(compactCodexTitle)
                    .font(.custom("Departure Mono", size: 11).weight(.semibold))
                    .lineLimit(1)
            } else if let track = island.nowPlaying {
                Text(track.title ?? "正在播放").font(.caption.weight(.semibold)).lineLimit(1)
            } else {
                Text("Apple Music").font(.caption.weight(.semibold)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var compactTrailingContent: some View {
        if reminders.presentation != nil {
            EmptyView()
        } else if codex.enabled {
            Text(codexCompactSummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        } else {
            Button(action: { island.togglePlayback() }) {
                if island.musicLaunchInProgress {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: island.isPlaying ? "pause.fill" : "play.fill")
                }
            }
        }
    }

    private var compactSymbol: String {
        guard let reminder = reminders.presentation else {
            if codex.enabled { return "terminal.fill" }
            return island.nowPlaying == nil ? "music.note" : (island.isPlaying ? "waveform" : "pause.fill")
        }
        switch reminder { case .countdown: return "timer"; case .focus: return "moon.stars.fill"; case .meeting: return "calendar"; case .breakReminder: return "figure.cooldown"; case .completed: return "bell.badge.fill" }
    }

    private var compactCodexTitle: String {
        guard let session = codex.activeSession else { return "等待 Codex 任务" }
        switch session.status {
        case .running: return "工作中…"
        case .waiting: return "需要确认"
        case .completed: return "任务已完成"
        case .failed: return "任务失败"
        }
    }

    private func compactTitle(_ value: IslandTimePresentation) -> String {
        switch value {
        case let .countdown(title, remaining, _, _): return "\(title) · \(time(Double(remaining)))"
        case let .focus(remaining, _): return "专注 · \(time(Double(remaining)))"
        case let .meeting(title, _, _): return title
        case .breakReminder: return "该休息一下了"
        case let .completed(title, _): return title
        }
    }

    @ViewBuilder private func reminderContent(_ value: IslandTimePresentation) -> some View {
        switch value {
        case let .countdown(title, remaining, total, paused):
            reminderLayout(symbol: "timer", color: .orange, large: time(Double(remaining)), title: title,
                           subtitle: paused ? "已暂停" : "正在倒计时", progress: Double(total - remaining) / Double(max(total, 1))) {
                Button(paused ? "继续" : "暂停") { reminders.toggleCountdownPause() }
                Button("结束") { reminders.stopTimer() }
            }
        case let .focus(remaining, total):
            reminderLayout(symbol: "moon.stars.fill", color: .purple, large: time(Double(remaining)), title: "专注模式",
                           subtitle: "保持专注，暂时关闭干扰", progress: Double(total - remaining) / Double(max(total, 1))) {
                Button("结束专注") { reminders.stopTimer() }
            }
        case let .meeting(title, start, url):
            reminderLayout(symbol: "calendar", color: .blue, large: start.formatted(date: .omitted, time: .shortened), title: title,
                           subtitle: meetingCountdown(start), progress: nil) {
                Button("稍后提醒") { reminders.dismissMeeting() }
                if url != nil { Button("加入会议") { reminders.joinMeeting() }.buttonStyle(.borderedProminent) }
            }
        case let .breakReminder(minutes):
            reminderLayout(symbol: "figure.cooldown", color: .green, large: nil, title: "该休息一下了",
                           subtitle: "你已经连续工作 \(minutes) 分钟", progress: nil) {
                Button("再工作 10 分钟") { reminders.dismissBreak() }
                Button("开始休息") { reminders.startBreak() }.buttonStyle(.borderedProminent)
            }
        case let .completed(title, message):
            completionContent(title: title, message: message)
        }
    }

    private func meetingCountdown(_ start: Date) -> String {
        let seconds = max(0, Int(start.timeIntervalSinceNow))
        return seconds < 60 ? "即将开始" : "\((seconds + 59) / 60) 分钟后开始"
    }

    private var memoContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 25, height: 25)
                    .background(.yellow, in: RoundedRectangle(cornerRadius: 6))
                Text("临时备忘").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(islandMemos.memos.count) 条")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(.white.opacity(0.07), in: Capsule())
            }
            HStack(spacing: 8) {
                TextField("记录一条临时备忘…", text: $memoText)
                    .focused($memoFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10).frame(height: 29)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.07)))
                    .onSubmit { addMemo() }
                Button { addMemo() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 29, height: 29)
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .background(.yellow, in: RoundedRectangle(cornerRadius: 7))
                .disabled(memoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            memoTable
        }.padding(.horizontal, 24).padding(.top, 29).padding(.bottom, 8)
    }

    private var memoTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("状态").frame(width: 40)
                Text("内容"); Spacer()
                Text("时间").frame(width: 56)
                Text("操作").frame(width: 58)
            }
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.38))
            .frame(height: 17)
            .background(.white.opacity(0.025))
            if islandMemos.memos.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").foregroundStyle(.yellow.opacity(0.7))
                    Text("还没有临时备忘").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(memoPageItems) { memo in memoRow(memo) }
                Spacer(minLength: 0)
            }
            Divider().overlay(.white.opacity(0.06))
            HStack {
                Text("已完成 \(islandMemos.completedCount) 条")
                Spacer()
                if memoPageCount > 1 {
                    HStack(spacing: 4) {
                        Button { memoPage = max(0, memoPage - 1) } label: {
                            Image(systemName: "chevron.left").frame(width: 18, height: 18)
                        }
                        .disabled(memoPage == 0)
                        Text("\(memoPage + 1)/\(memoPageCount)")
                            .monospacedDigit().frame(minWidth: 25)
                        Button { memoPage = min(memoPageCount - 1, memoPage + 1) } label: {
                            Image(systemName: "chevron.right").frame(width: 18, height: 18)
                        }
                        .disabled(memoPage >= memoPageCount - 1)
                    }
                    .foregroundStyle(.white.opacity(0.62))
                }
                Button("清除已完成") { islandMemos.clearCompleted() }.disabled(islandMemos.completedCount == 0)
                Button("全部删除") { islandMemos.deleteAll() }.foregroundStyle(.red.opacity(0.8))
            }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).frame(height: 21)
        }
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: islandMemos.memos.count) { _, _ in
            memoPage = min(memoPage, max(0, memoPageCount - 1))
        }
    }

    private var memoPageCount: Int {
        max(1, Int(ceil(Double(islandMemos.orderedMemos.count) / 3.0)))
    }

    private var memoPageItems: [IslandMemo] {
        let memos = islandMemos.orderedMemos
        let start = min(memoPage * 3, memos.count)
        let end = min(start + 3, memos.count)
        return Array(memos[start..<end])
    }

    private func memoRow(_ memo: IslandMemo) -> some View {
        HStack(spacing: 7) {
            Button { islandMemos.toggleCompleted(memo.id) } label: {
                Image(systemName: memo.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(memo.completed ? .green : .white.opacity(0.45)).frame(width: 40)
            }
            Text(memo.text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .strikethrough(memo.completed).foregroundStyle(.white.opacity(memo.completed ? 0.38 : 0.88))
            Spacer(minLength: 5)
            Text(memoAge(memo.createdAt)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.38)).frame(width: 56)
            HStack(spacing: 9) {
                Button { islandMemos.togglePinned(memo.id) } label: {
                    Image(systemName: memo.pinned ? "pin.fill" : "pin").foregroundStyle(memo.pinned ? .yellow : .white.opacity(0.42))
                }
                Button { islandMemos.delete(memo.id) } label: {
                    Image(systemName: "trash").foregroundStyle(.white.opacity(0.42))
                }
            }.frame(width: 58)
        }
        .frame(height: 31)
        .background(memo.pinned ? Color.yellow.opacity(0.035) : .clear)
        .overlay(alignment: .bottom) { Divider().overlay(.white.opacity(0.055)) }
    }

    private func addMemo() {
        if islandMemos.add(memoText) { memoText = "" }
    }

    private func memoAge(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
    }

    private func completionContent(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 62, height: 62).background(.orange, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 19, weight: .semibold))
                    Text(message).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(2)
                    Text("单击屏幕任意位置可关闭").font(.caption2).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("\(reminders.completionRemainingSeconds)").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("秒后关闭").font(.caption2).foregroundStyle(.white.opacity(0.55))
                }.frame(width: 66)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.orange).frame(width: proxy.size.width * CGFloat(reminders.completionRemainingSeconds) / CGFloat(max(reminders.completionDisplaySeconds, 1)))
                }
            }.frame(height: 5)
        }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func reminderLayout<Actions: View>(symbol: String, color: Color, large: String?, title: String,
                                                subtitle: String, progress: Double?, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 58, height: 58).background(color, in: RoundedRectangle(cornerRadius: 14))
                if let large { Text(large).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit() }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
                Spacer(); HStack(spacing: 10) { actions() }
            }
            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(color).frame(width: proxy.size.width * min(max(progress, 0), 1))
                    }
                }.frame(height: 5)
            }
        }
        .padding(.horizontal, 28).padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var codexContent: some View {
        let fontSize = codex.contentFontSize
        let ordered = codex.sessions.sorted { lhs, rhs in
            let rank: (CodexIslandSession.Status) -> Int = {
                switch $0 { case .waiting: 0; case .running: 1; case .failed: 2; case .completed: 3 }
            }
            if rank(lhs.status) != rank(rhs.status) { return rank(lhs.status) < rank(rhs.status) }
            return lhs.updatedAt > rhs.updatedAt
        }
        return VStack(spacing: 0) {
            if codex.enabled, !ordered.isEmpty {
                ForEach(Array(ordered.prefix(3).enumerated()), id: \.element.id) { offset, session in
                    codexSessionRow(session, fontSize: fontSize)
                    if offset == 0, ordered.count > 1 {
                        Divider().overlay(.white.opacity(0.08)).padding(.leading, 44)
                    }
                }
                if ordered.count == 4, let session = ordered.dropFirst(3).first {
                    compactCodexSessionRow(session, fontSize: fontSize)
                } else if ordered.count > 4 {
                    Button { codex.openCodex() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 34)
                            Text("还有 \(ordered.count - 3) 个会话")
                                .font(.custom("Departure Mono", size: max(9, fontSize - 1)).weight(.semibold))
                                .foregroundStyle(.white.opacity(0.62))
                            Spacer()
                            Text("打开 Codex")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.blue.opacity(0.95))
                        }
                    }
                    .frame(height: 36)
                }
            } else {
                HStack(spacing: 10) {
                    CodexActivityIndicator(status: nil)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(codex.enabled ? "Codex" : "Codex 集成未启用")
                            .font(.custom("Departure Mono", size: fontSize).weight(.semibold))
                            .lineLimit(1)
                        Text(codex.enabled ? "暂无运行中的任务" : "可在灵动岛设置中启用 Codex Hooks")
                            .font(.custom("Departure Mono", size: max(9, fontSize - 2)))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { codex.openCodex() } label: {
                        Text("打开 Codex")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.blue.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.blue.opacity(0.95))
                    }
                }
                .frame(height: 51)
            }
        }
        .padding(.horizontal, 18).padding(.top, 32).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func codexSessionRow(_ session: CodexIslandSession, fontSize: Double) -> some View {
        HStack(spacing: 10) {
                CodexActivityIndicator(status: session.status)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if codex.showProjectName {
                            Text(session.project).font(.custom("Departure Mono", size: max(9, fontSize - 2)).weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                            Text("·").foregroundStyle(.white.opacity(0.3))
                        }
                        Text(session.title).font(.custom("Departure Mono", size: fontSize).weight(.semibold)).lineLimit(1)
                    }
                    if codex.showActivityDetail {
                        Text(session.detail).font(.custom("Departure Mono", size: max(9, fontSize - 2))).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if session.status == .waiting {
                    Button("允许") { codex.respondToApproval(for: session, allow: true) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    Button("拒绝") { codex.respondToApproval(for: session, allow: false) }
                        .buttonStyle(.bordered)
                } else {
                    codexSessionTrailing(session)
                }
            }
        .contentShape(Rectangle())
        .onTapGesture { if session.status != .waiting { codex.openCodex(session) } }
        .frame(height: 51)
        .background(session.status == .completed ? Color.white.opacity(0.055) : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func compactCodexSessionRow(_ session: CodexIslandSession, fontSize: Double) -> some View {
        Button { codex.openCodex(session) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(codexColor(session.status).opacity(0.5))
                    .frame(width: 7, height: 7)
                    .frame(width: 34)
                if codex.showProjectName {
                    Text(session.project)
                        .font(.custom("Departure Mono", size: max(9, fontSize - 2)).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("·").foregroundStyle(.white.opacity(0.3))
                }
                Text(session.title)
                    .font(.custom("Departure Mono", size: max(9, fontSize - 1)).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 8)
                codexSessionTrailing(session)
            }
        }
        .frame(height: 36)
    }

    private func codexSessionTrailing(_ session: CodexIslandSession) -> some View {
        Group {
            if session.status == .waiting {
                Text("打开审批").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
            } else {
                Text("Codex").font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.blue.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.blue.opacity(0.95))
            }
            Text(relativeAge(session.updatedAt))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 34, alignment: .trailing)
            Circle().fill(codexColor(session.status)).frame(width: 6, height: 6)
        }
    }

    private func codexColor(_ status: CodexIslandSession.Status) -> Color {
        switch status { case .running: return .blue; case .waiting: return .orange; case .completed: return .green; case .failed: return .red }
    }
    private func codexSymbol(_ status: CodexIslandSession.Status) -> String {
        switch status { case .running: return "terminal.fill"; case .waiting: return "exclamationmark.triangle.fill"; case .completed: return "checkmark"; case .failed: return "xmark" }
    }
    private func codexStatus(_ status: CodexIslandSession.Status) -> String {
        switch status { case .running: return "运行中"; case .waiting: return "等待确认"; case .completed: return "已完成"; case .failed: return "失败" }
    }
    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    private var expandedContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 26) {
            if let track = island.nowPlaying {
                artwork(for: track)
                    .scaleEffect(1.8)
                    .frame(width: 155, height: 128)
                    .background(alignment: .trailing) {
                        ZStack {
                            Circle().fill(Color(white: 0.055))
                            ForEach(0..<5) { index in
                                Circle().stroke(.white.opacity(0.07), lineWidth: 1)
                                    .padding(CGFloat(index * 6 + 5))
                            }
                            Circle().fill(.pink.opacity(0.45)).frame(width: 28, height: 28)
                        }.frame(width: 124, height: 124).offset(x: 30)
                    }
                VStack(alignment: .leading, spacing: 7) {
                    Label(island.isPlaying ? "NOW PLAYING" : "已暂停", systemImage: "waveform")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.pink)
                    Text(track.title ?? "正在播放")
                        .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text([track.artist, track.album].compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
            } else {
                Rectangle()
                    .fill(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 5) {
                    Label("音乐随时待命", systemImage: "waveform").font(.system(size: 10)).foregroundStyle(.orange)
                    Text("Apple Music").font(.system(size: 22, weight: .semibold))
                    Text(island.musicLaunchInProgress ? "正在打开 Apple Music…" : "点击播放以打开音乐并继续播放")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                if island.nowPlaying != nil {
                    Button(action: { DynamicIslandService.sendMediaKey(20) }) { Image(systemName: "backward.fill") }
                }
                Button(action: { island.togglePlayback() }) {
                    Group {
                    if island.musicLaunchInProgress {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: island.isPlaying ? "pause.fill" : "play.fill")
                    }
                    }
                    .frame(width: 58, height: 58)
                    .background(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                }
                if island.nowPlaying != nil {
                    Button(action: { DynamicIslandService.sendMediaKey(19) }) { Image(systemName: "forward.fill") }
                }
            }
            .font(.system(size: 17, weight: .semibold))
            }
            .frame(height: 128)
            if island.duration > 0 {
                VStack(spacing: 7) {
                    HStack {
                        Label("播放进度", systemImage: "timeline.selection")
                        Spacer()
                        Text("剩余 \(time(max(island.duration - island.elapsedTime, 0)))")
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
                    HStack(spacing: 9) {
                        Text(time(island.elapsedTime)).monospacedDigit()
                    ContrastSlider(value: Binding(get: { island.elapsedTime }, set: { island.seek(to: $0) }),
                                   range: 0...max(island.duration, 1))
                        Text(time(island.duration)).monospacedDigit()
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.84))
                }
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.065)))
            }
            HStack {
                Label("好音乐，总能让生活多一点色彩。", systemImage: "music.note")
                Spacer()
            }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 13)
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private func artwork(for track: RadialNowPlayingSnapshot) -> some View {
        if let data = track.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Rectangle()
                .fill(LinearGradient(colors: [.purple, .pink, .orange],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.white))
        }
    }
}

private struct ContrastSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = min(max((value - range.lowerBound) /
                                    max(range.upperBound - range.lowerBound, 0.0001), 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: 6)
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.18, blue: 0.52),
                                                  Color(red: 1.0, green: 0.48, blue: 0.22)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, width * progress), height: 6)
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .offset(x: min(max(width * progress - 7, 0), max(width - 14, 0)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let fraction = min(max(gesture.location.x / width, 0), 1)
                value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("滑块")
        .accessibilityValue(String(format: "%.0f%%", min(max((value - range.lowerBound) /
            max(range.upperBound - range.lowerBound, 0.0001), 0), 1) * 100))
    }
}

extension DynamicIslandService {
    fileprivate static func sendMediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (Int(key) << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
