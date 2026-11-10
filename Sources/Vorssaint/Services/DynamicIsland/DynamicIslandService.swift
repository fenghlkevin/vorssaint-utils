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
    var expandedCanvasSize: NSSize {
        let codex = CodexIslandService.shared
        let width = IslandUtilityLayout.panelWidth(codex.panelWidth)
        switch expandedCanvas {
        case "codex": return NSSize(width: width, height: codex.islandContentHeight)
        case "music": return NSSize(width: width, height: 246)
        case "time": return NSSize(width: width, height: 260)
        case "memo": return NSSize(width: width, height: 310)
        default: return NSSize(width: 780, height: 310)
        }
    }
    var expandedSize: NSSize {
        NSSize(width: expandedCanvasSize.width * expandedScale,
               height: expandedCanvasSize.height * expandedScale)
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
    @Published private(set) var musicShuffle = false
    @Published private(set) var musicRepeat = "off"
    private let mediaCommands = IslandMediaCommands()
    private var modesQueryInFlight = false
    private var seekPendingUntil = Date.distantPast
    var scriptedPlayer: String? {
        switch nowPlaying?.appBundleIdentifier {
        case "com.apple.Music": return "Music"
        case "com.spotify.client": return "Spotify"
        default: return nil
        }
    }
    var canSeek: Bool { nowPlaying != nil && duration > 0 && (scriptedPlayer != nil || mediaCommands.canSeek) }
    var musicSourceName: String {
        guard let identifier = nowPlaying?.appBundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return "Apple Music" }
        return url.deletingPathExtension().lastPathComponent
    }
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
    @Published private(set) var isMusicVolumePopoverPresented = false
    private var window: NSWindow?
    private var monitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var refreshTimer: Timer?
    private var hoverTimer: Timer?
    private var lastMediaRefresh = Date.distantPast
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
    private var dismissedByOutsideClick = false
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
            w.hidesOnDeactivate = false
            // This is a screen overlay, not a desktop window. Keep Show Desktop
            // and Stage Manager from moving it with the application's windows.
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .canJoinAllApplications, .stationary, .ignoresCycle]
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
        // Keep the hosting canvas stable while the visible island animates inside it.
        // It accommodates every tab and the largest AI panel without AppKit resizing.
        let size = NSSize(width: 780 * expandedScale, height: 560 * expandedScale)
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
        // Keep attention/log updates responsive without querying MediaRemote and
        // Music every second when the compact island has no playback to show.
        let mediaInterval: TimeInterval = expanded || isPlaying || musicLaunchInProgress ? 1 : 5
        let now = Date()
        guard now.timeIntervalSince(lastMediaRefresh) >= mediaInterval else { return }
        lastMediaRefresh = now
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
        if Date() >= seekPendingUntil, elapsedTime != nextElapsed { elapsedTime = nextElapsed }
        if duration != nextDuration { duration = nextDuration }
        if outputVolume != nextVolume { outputVolume = nextVolume }
        refreshPlaybackModes()
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
        else if let player = scriptedPlayer { runPlayerCommand("playpause", player: player) }
        else if !mediaCommands.send(2) { Self.sendMediaKey(16) }
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
        guard canSeek, value.isFinite else { return }
        let position = min(max(value, 0), duration)
        elapsedTime = position
        seekPendingUntil = Date().addingTimeInterval(1.5)
        if let player = scriptedPlayer { runPlayerCommand("set player position to \(position)", player: player) }
        else { mediaCommands.seek(to: position) }
    }

    func skipTrack(forward: Bool) {
        if let player = scriptedPlayer { runPlayerCommand(forward ? "next track" : "previous track", player: player) }
        else if !mediaCommands.send(forward ? 4 : 5) { Self.sendMediaKey(forward ? 19 : 20) }
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        outputVolume = min(max(value, 0), 1)
        _ = AppVolumeMixer.setSystemOutputVolume(outputVolume)
    }

    func toggleMusicShuffle() {
        guard let player = scriptedPlayer else { return }
        runPlayerCommand(player == "Music" ? "set shuffle enabled to not shuffle enabled" : "set shuffling to not shuffling", player: player)
    }

    func cycleMusicRepeat() {
        guard let player = scriptedPlayer else { return }
        let command = player == "Spotify" ? "set repeating to not repeating" : """
        if song repeat is off then
            set song repeat to all
        else if song repeat is all then
            set song repeat to one
        else
            set song repeat to off
        end if
        """
        runPlayerCommand(command, player: player)
    }

    private func runPlayerCommand(_ command: String, player: String) {
        playerQueryQueue.async { [weak self] in
            _ = AppleScriptRunner.runDetailed("tell application \"\(player)\"\n\(command)\nend tell")
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func refreshPlaybackModes() {
        guard let player = scriptedPlayer else {
            if musicShuffle { musicShuffle = false }
            if musicRepeat != "off" { musicRepeat = "off" }
            return
        }
        guard !modesQueryInFlight else { return }
        modesQueryInFlight = true
        playerQueryQueue.async { [weak self] in
            let expression = player == "Music"
                ? "(shuffle enabled as text) & \"|\" & (song repeat as text)"
                : "(shuffling as text) & \"|\" & (repeating as text)"
            let result = AppleScriptRunner.runDetailed("tell application \"\(player)\" to return \(expression)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.modesQueryInFlight = false
                guard self.scriptedPlayer == player, result.ok else { return }
                let fields = result.output.components(separatedBy: "|")
                self.musicShuffle = fields.first == "true"
                let mode = fields.last ?? "off"
                self.musicRepeat = mode == "true" ? "all" : (mode == "false" ? "off" : mode)
            }
        }
    }

    func openMusic() {
        let identifier = nowPlaying?.appBundleIdentifier ?? "com.apple.Music"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func activateTimeReminder() {
        guard !presentationSuspended else { pendingTimeAttention = true; return }
        dismissedByOutsideClick = false
        timeReminderActivationID = UUID()
        show()
        if !expanded { setExpanded(true) }
    }

    func activateCodex(duration: TimeInterval = 5) {
        guard !presentationSuspended else { pendingCodexAttention = true; return }
        dismissedByOutsideClick = false
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

    func setMusicVolumePopoverPresented(_ presented: Bool) {
        isMusicVolumePopoverPresented = presented
        if !presented { updateHoverState() }
    }

    func setExpanded(_ value: Bool) {
        if value {
            dismissedByOutsideClick = false
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
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
        if !value { CodexIslandService.shared.showAllSessions() }
        show()
    }

    private func updateHoverState() {
        updateActiveDisplayFromMouseClick()
        guard let window, window.isVisible else { return }
        if window.isKeyWindow || isMusicVolumePopoverPresented { return }
        if case .completed = TimeReminderService.shared.presentation {
            if !expanded { activateTimeReminder() }
            return
        }
        if musicLaunchInProgress, !dismissedByOutsideClick {
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
        handlePointerClick(at: NSEvent.mouseLocation)
    }

    private func activateDisplay(at point: CGPoint) {
        guard let screen = Self.screen(at: point),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              number != activeDisplayNumber else { return }
        activeDisplayNumber = number
        if selectedDisplay == "active" { show() }
    }

    private func handlePointerClick(at point: CGPoint) {
        // The backing window is larger than the visible panel. Hit-test the
        // displayed island before potentially moving it to another screen.
        if expanded, let window {
            let size = expandedSize
            let visibleFrame = NSRect(x: window.frame.midX - size.width / 2,
                                      y: window.frame.maxY - size.height,
                                      width: size.width, height: size.height)
            if !visibleFrame.contains(point) {
                dismissedByOutsideClick = true
                codexAttentionDeadline = nil
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
                transition(toExpanded: false)
            }
        }
        if TimeReminderService.shared.isCompletionPresented {
            TimeReminderService.shared.dismissCompletion()
        }
        activateDisplay(at: point)
    }


}

struct CodexActivityIndicator: View {
    @ObservedObject private var island = DynamicIslandService.shared
    let status: CodexIslandSession.Status?

    var body: some View {
        if status == .running, !island.presentationSuspended {
            // A small status glyph does not need a display-link animation. A
            // periodic schedule avoids continuously driving the hosting view.
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
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
    @ObservedObject private var island = DynamicIslandService.shared
    @ObservedObject private var reminders = TimeReminderService.shared
    @ObservedObject private var codex = CodexIslandService.shared
    @State private var selectedTab: IslandTab = .codex
    @State private var selectedCalendarDate = Date()
    @State private var showingTimerCalendar = false
    @State private var approvalDetailsID: String?
    var body: some View {
        Group {
            if island.showsExpandedContent {
                expandedPanel
                    // Only opacity participates in opening. The contents already
                    // have their final geometry, independent of the shell below.
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
        .frame(width: island.expanded ? island.expandedSize.width : island.compactWidth,
               height: island.expanded ? island.expandedSize.height : island.compactHeight,
               alignment: .top)
        .background(Color.black, in: UnevenRoundedRectangle(topLeadingRadius: 0,
                                                            bottomLeadingRadius: 18,
                                                            bottomTrailingRadius: 18,
                                                            topTrailingRadius: 0,
                                                            style: .continuous))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0,
                                         bottomLeadingRadius: 18,
                                         bottomTrailingRadius: 18,
                                         topTrailingRadius: 0,
                                         style: .continuous))
        .animation(.smooth(duration: 0.28), value: island.expandedCanvasSize)
        .animation(.easeInOut(duration: 0.16), value: selectedTab)
        .onAppear { ensureSelectedTabIsVisible(); island.setExpandedCanvas(canvas(for: selectedTab)) }
        .onChange(of: visibleTabsSignature) { _, _ in ensureSelectedTabIsVisible() }
        .onChange(of: reminders.presentation) { oldValue, newValue in
            if oldValue == nil, newValue != nil, island.showTimerTab { selectedTab = .time }
            // Keep the timer composer visible after cancelling or finishing.
        }
        .onChange(of: island.timeReminderActivationID) { _, _ in
            if island.showTimerTab { selectedTab = .time }
        }
        .onChange(of: island.codexActivationID) { _, _ in
            if island.showAIHookTab { selectedTab = .codex }
        }
        .onChange(of: selectedTab) { _, value in
            island.setCodexTabActive(value == .codex)
            island.setExpandedCanvas(canvas(for: value))
        }
        // The hosting window retains the expanded canvas when collapsed.
        // Fill it only AFTER sizing the island, so AppKit cannot stretch the
        // root's compact frame or anchor it at the window's leading edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var expandedPanel: some View {
        Group {
            switch selectedTab {
            case .time:
                if let reminder = reminders.presentation, isTimerAlert(reminder) { reminderContent(reminder) }
                else { timeSetupContent }
            case .music: expandedContent
            case .memo: memoContent
            case .codex: codexContent
            }
        }
        .frame(width: island.expandedCanvasSize.width, height: island.expandedCanvasSize.height)
        .overlay(alignment: .topTrailing) { modeSwitcher }
        .scaleEffect(island.expandedScale, anchor: .top)
        .frame(width: island.expandedSize.width, height: island.expandedSize.height, alignment: .top)
        // Do not inherit the shell's resize animation into trailing-aligned
        // toolbars, spacers, or the built-in display's scale transform.
        .transaction { $0.animation = nil }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            Spacer()
            if island.showAIHookTab {
                Button { codex.showAllSessions(); selectedTab = .codex } label: {
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

    private func canvas(for tab: IslandTab) -> String {
        switch tab { case .codex: "codex"; case .music: "music"; case .time: "time"; case .memo: "memo" }
    }

    private func isTimerAlert(_ reminder: IslandTimePresentation) -> Bool {
        switch reminder { case .countdown, .focus: false; default: true }
    }

    private var timeSetupContent: some View {
        IslandTimerPanel(running: reminders.runningTimer, start: { title, seconds in
            if title == "专注" { reminders.startFocus(minutes: seconds / 60) }
            else { reminders.startCountdown(title: title, seconds: seconds) }
        }, pause: { reminders.toggleCountdownPause() }, cancel: { reminders.stopTimer() })
        .overlay(alignment: .topLeading) {
            if reminders.calendarEnabled {
                Button { showingTimerCalendar.toggle() } label: {
                    Label("日程", systemImage: "calendar").font(.system(size: 10)).padding(10)
                }
                .popover(isPresented: $showingTimerCalendar) {
                    calendarCard.padding(14).frame(width: 360, height: 280).background(.black)
                }
            }
        }
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
        IslandMemoPanel(service: IslandMemoService.shared)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(codex.waitingCount > 0 ? .orange : .blue).frame(width: 6, height: 6)
                Text("AI 会话").font(.system(size: 11, weight: .semibold))
                Text(codexCompactSummary).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            .padding(.horizontal, 18).frame(height: 30)
            if codex.enabled, codex.hookHealth != .ready {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(codex.hookHealth.message).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("检查") { codex.checkHookHealth() }
                }
                .font(.system(size: 11)).foregroundStyle(.orange)
                .padding(.horizontal, 18).padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if codex.displayedSessions.isEmpty && !codex.recentSessionsExpanded {
                        HStack(spacing: 12) {
                            CodexActivityIndicator(status: nil).frame(width: 34)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(codex.enabled ? (codex.panelPlan.allCompleted ? "一切已完成" : "一切就绪") : "Codex 集成未启用")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(codex.enabled ? (codex.panelPlan.allCompleted ? "最近 \(codex.panelPlan.recent.count) 个会话" : "任务开始后，会在这里显示进度") : "在灵动岛设置中启用 AI Hook")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                        }.padding(14).frame(height: 100)
                    } else {
                        ForEach(codex.displayedSessions) { session in
                            codexSessionRow(session, fontSize: codex.contentFontSize)
                        }
                    }
                    if codex.recentSessionsExpanded {
                        ForEach(codex.panelPlan.recent) { session in
                            codexSessionRow(session, fontSize: codex.contentFontSize)
                        }
                    }
                    if let error = codex.lastError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }.padding(.horizontal, 10)
            }
            if !codex.panelPlan.recent.isEmpty {
                Button { codex.recentSessionsExpanded.toggle() } label: {
                    HStack {
                        Image(systemName: codex.recentSessionsExpanded ? "chevron.down" : "chevron.right")
                        Text("最近完成 · \(codex.panelPlan.recent.count) 个会话")
                        Spacer()
                    }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 18).frame(height: 30)
                }
            }
            HStack {
                if codex.panelPlan.focused {
                    Button("查看全部（\(codex.sessions.count)）") { codex.showAllSessions() }
                        .font(.system(size: 10)).foregroundStyle(.blue)
                } else {
                    Text(codex.displayedSessions.count > 3 ? "滚动查看更多 · 点击会话返回任务" : "点击会话返回任务")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Button { codex.openCodex() } label: {
                    Label("打开 Codex", systemImage: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
            }.padding(.horizontal, 18).frame(height: 26)
        }.padding(.top, 28).padding(.bottom, 6)
    }

    private func codexSessionRow(_ session: CodexIslandSession, fontSize: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { codex.openCodex(session) } label: {
                HStack(spacing: 10) {
                    CodexActivityIndicator(status: session.status).frame(width: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if codex.showProjectName {
                                Text(session.project).lineLimit(1)
                                Text("·")
                            }
                            Text("Codex")
                        }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        Text(session.title).font(.system(size: fontSize, weight: .semibold))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if codex.showActivityDetail, session.status != .waiting {
                            Text(session.detail).font(.system(size: max(10, fontSize - 1)))
                                .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Label(codexStatus(session.status), systemImage: codexSymbol(session.status))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(codexColor(session.status))
                        Text(relativeAge(session.updatedAt)).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }.contentShape(Rectangle())
            }
            if session.status == .waiting {
                Text(session.detail).font(.system(size: max(10, fontSize - 1), design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                HStack(spacing: 8) {
                    if let request = codex.approval(for: session) {
                    if let feedback = codex.approvalFeedback[request.id] {
                        Label(feedback, systemImage: "checkmark.circle")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    } else {
                        Button("查看完整操作") { approvalDetailsID = request.id }
                            .popover(isPresented: Binding(get: { approvalDetailsID == request.id }, set: { if !$0 { approvalDetailsID = nil } })) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Codex 请求执行的操作").font(.headline)
                                        Text(request.operation).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                        Text("只批准本次请求；此面板不会改变 Codex 的权限策略。")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(width: 520, height: 320)
                            }
                        Spacer()
                        Button("拒绝") { codex.respondToApproval(for: session, requestID: request.id, allow: false) }
                            .buttonStyle(.bordered)
                        Button("允许") { codex.respondToApproval(for: session, requestID: request.id, allow: true) }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }
                    } else {
                        Text("需要你的回答").font(.system(size: 10)).foregroundStyle(.orange)
                        Spacer()
                        Button("返回 Codex") { codex.openCodex(session) }.buttonStyle(.borderedProminent).tint(.orange)
                    }
                }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(height: IslandSessionPresentation.rowHeight(session) - 4)
        .background(codexColor(session.status).opacity(session.status == .waiting ? 0.08 : 0.0),
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(codexColor(session.status).opacity(session.status == .waiting ? 0.16 : 0.0)))
        .padding(.vertical, 2)
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
        IslandMusicPanel(title: island.nowPlaying?.title ?? "正在播放",
                         artist: island.nowPlaying?.artist ?? "未知艺人",
                         artwork: island.nowPlaying?.artworkData.flatMap { NSImage(data: $0) },
                         source: island.musicSourceName, hasTrack: island.nowPlaying != nil,
                         playing: island.isPlaying, launching: island.musicLaunchInProgress,
                         elapsed: island.elapsedTime, duration: island.duration, canSeek: island.canSeek,
                         shuffle: island.musicShuffle, repeatMode: island.musicRepeat,
                         supportsPlaybackModes: island.scriptedPlayer != nil, volume: island.outputVolume,
                         playPause: { island.togglePlayback() }, previous: { island.skipTrack(forward: false) },
                         next: { island.skipTrack(forward: true) }, seek: { island.seek(to: $0) },
                         setVolume: { island.setVolume($0) }, toggleShuffle: { island.toggleMusicShuffle() },
                         cycleRepeat: { island.cycleMusicRepeat() }, openPlayer: { island.openMusic() },
                         setVolumePopoverPresented: { island.setMusicVolumePopoverPresented($0) })
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
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
