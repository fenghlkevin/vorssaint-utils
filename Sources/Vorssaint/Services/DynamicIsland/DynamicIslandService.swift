import AppKit
import SwiftUI

private final class DynamicIslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DynamicIslandService: ObservableObject {
    static let shared = DynamicIslandService()
    var expandedSize: NSSize {
        let codex = CodexIslandService.shared
        let fullSessionCount = min(codex.sessions.count, 3)
        let overflowHeight = codex.sessions.count > 3 ? 38.0 : 0
        // Keep one stable expanded canvas across tabs. Resizing the AppKit
        // window while SwiftUI swaps Codex, music and timer content makes the
        // lower edge bounce and briefly clips the incoming tab.
        let contentHeight = max(176, 42 + Double(fullSessionCount * 54) + overflowHeight)
        return NSSize(width: min(max(codex.panelWidth, 520), 760),
                      height: min(contentHeight, min(max(codex.panelHeight, 176), 560)))
    }
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: DefaultsKey.dynamicIslandEnabled); syncWithPreferences() } }
    @Published var selectedDisplay: String { didSet { UserDefaults.standard.set(selectedDisplay, forKey: DefaultsKey.dynamicIslandDisplay); rebuild() } }
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
    @Published private(set) var timeReminderActivationID = UUID()
    @Published private(set) var codexActivationID = UUID()
    @Published private(set) var codexTabActive = true
    private var window: NSWindow?
    private var monitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var refreshTimer: Timer?
    private var hoverTimer: Timer?
    private let playerQueryQueue = DispatchQueue(label: "com.vorssaint.dynamic-island.player-query",
                                                  qos: .utility)
    private var playerQueryInFlight = false
    private var cachedArtworkKey: String?
    private var cachedArtworkData: Data?
    private var collapseWorkItem: DispatchWorkItem?
    private var musicLaunchTimeoutWorkItem: DispatchWorkItem?
    private var codexAttentionDeadline: Date?
    private var transitionInFlight = false
    private var activeDisplayNumber: NSNumber?
    private var primaryButtonWasDown = false
    private init() {
        enabled = UserDefaults.standard.object(forKey: DefaultsKey.dynamicIslandEnabled) as? Bool ?? true
        selectedDisplay = UserDefaults.standard.string(forKey: DefaultsKey.dynamicIslandDisplay) ?? "active"
        activeDisplayNumber = Self.screen(at: NSEvent.mouseLocation)?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
    func syncWithPreferences() {
        guard AppFeature.dynamicIsland.isAvailable, enabled else { stop(); return }
        start()
    }
    func start() {
        guard enabled, refreshTimer == nil else { return }
        CodexIslandService.shared.syncHookInstallation()
        show(); refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            TimeReminderService.shared.tick(); self?.refresh(); self?.show()
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateHoverState()
        }
        monitor = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.handlePointerClick(at: NSEvent.mouseLocation) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handlePointerClick(at: NSEvent.mouseLocation)
            return event
        }
    }
    func stop() { if let monitor { NotificationCenter.default.removeObserver(monitor) }; monitor = nil; if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }; globalClickMonitor = nil; if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }; localClickMonitor = nil; refreshTimer?.invalidate(); refreshTimer = nil; hoverTimer?.invalidate(); hoverTimer = nil; musicLaunchTimeoutWorkItem?.cancel(); musicLaunchTimeoutWorkItem = nil; musicLaunchInProgress = false; hide() }
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
        guard let screen = targetScreen else { return }
        if window == nil {
            let w = NSPanel(contentRect: .zero,
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
        let hasNotch = screen.safeAreaInsets.top > 0
        let notchWidth: CGFloat = {
            guard hasNotch,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else { return 0 }
            return max(0, right.minX - left.maxX)
        }()
        let preferredCompactWidth: CGFloat = CodexIslandService.shared.enabled ? 270 : 230
        compactWidth = hasNotch ? max(preferredCompactWidth, notchWidth + 20) : preferredCompactWidth
        // A physical notch occupies the safe-area height and cannot receive a
        // pointer. Keep 12 pt of the virtual island below it as a reliable
        // hover target on 14/16-inch MacBook Pro displays.
        compactHeight = hasNotch ? max(42, screen.safeAreaInsets.top + 12) : 34
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
        } else {
            window?.setFrame(frame, display: true)
        }
        window?.ignoresMouseEvents = !expanded
        window?.orderFrontRegardless()
    }
    private func hide() { window?.orderOut(nil) }
    private func rebuild() { guard enabled else { return }; hide(); show() }
    private func refresh() {
        guard enabled else { return }
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
        if nowPlaying != snapshot { nowPlaying = snapshot }
        if snapshot != nil {
            musicLaunchTimeoutWorkItem?.cancel()
            musicLaunchTimeoutWorkItem = nil
            musicLaunchInProgress = false
        }
        isPlaying = snapshot?.isPlaying ?? false
        elapsedTime = snapshot?.elapsedTime ?? 0
        duration = snapshot?.duration ?? 0
        outputVolume = AppVolumeMixer.systemOutputVolumeLevel() ?? outputVolume
        show()
    }

    /// MediaRemote returns nil on some recent macOS builds even while Music is
    /// visibly playing. Query Music only as a fallback; other players still use
    /// the system-wide route above.
    private func refreshAppleMusicFallback() {
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

    func activateTimeReminder() {
        timeReminderActivationID = UUID()
        show()
        if !expanded { setExpanded(true) }
    }

    func activateCodex(duration: TimeInterval = 5) {
        codexActivationID = UUID()
        codexAttentionDeadline = Date().addingTimeInterval(duration)
        show()
        if !expanded { setExpanded(true) }
    }

    func setCodexTabActive(_ active: Bool) {
        guard codexTabActive != active else { return }
        codexTabActive = active
    }

    func setExpanded(_ value: Bool) {
        guard !transitionInFlight else { return }
        if value {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            guard !expanded else { return }
            transition(toExpanded: true)
            return
        }
        guard collapseWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.expanded else { return }
            self.collapseWorkItem = nil
            self.transition(toExpanded: false)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func transition(toExpanded value: Bool) {
        guard window != nil else { return }
        transitionInFlight = true
        if value {
            expanded = true
            show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.expanded else { return }
                withAnimation(.easeOut(duration: 0.18)) { self.showsExpandedContent = true }
                self.transitionInFlight = false
            }
        } else {
            withAnimation(.easeOut(duration: 0.1)) { showsExpandedContent = false }
            expanded = false
            show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                self?.transitionInFlight = false
            }
        }
    }

    private func updateHoverState() {
        updateActiveDisplayFromMouseClick()
        guard let window, window.isVisible else { return }
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
        if expanded {
            if !mouseInside { setExpanded(false) }
        } else if mouseInside {
            setExpanded(true)
        }
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

private struct CodexActivityIndicator: View {
    let status: CodexIslandSession.Status?

    var body: some View {
        if status == .running {
            TimelineView(.animation(minimumInterval: 0.16)) { timeline in
                pixelIndicator(phase: Int(timeline.date.timeIntervalSinceReferenceDate / 0.18) % 3)
            }
        } else {
            pixelIndicator(phase: nil)
        }
    }

    private func pixelIndicator(phase: Int?) -> some View {
        HStack(spacing: 3) {
            PixelCodexAgent(color: color, intensity: phase == nil ? 0.82 : 1)
            VStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(color)
                        .frame(width: 3, height: 4)
                        .opacity(barOpacity(index, phase: phase))
                }
            }
        }
        .frame(width: 31, height: 18)
        .shadow(color: color.opacity(status == .running ? 0.55 : 0.28), radius: 3)
    }

    private func barOpacity(_ index: Int, phase: Int?) -> Double {
        guard let phase else { return status == .completed ? 0.58 : 0.82 }
        return index == phase ? 1 : 0.28
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

private struct PixelCodexAgent: View {
    let color: Color
    let intensity: Double

    // A tiny seven-column agent mark drawn cell-by-cell so it stays crisp at
    // menu-bar scale and reads like the activity glyph in Vibe Island.
    private let cells: [(Int, Int)] = [
        (2, 0), (3, 0), (4, 0),
        (1, 1), (2, 1), (3, 1), (4, 1), (5, 1),
        (0, 2), (1, 2), (3, 2), (5, 2), (6, 2),
        (0, 3), (1, 3), (2, 3), (3, 3), (4, 3), (5, 3), (6, 3),
        (1, 4), (3, 4), (5, 4)
    ]

    var body: some View {
        Canvas { context, _ in
            for (column, row) in cells {
                context.fill(
                    Path(CGRect(x: CGFloat(column * 3), y: CGFloat(row * 3), width: 3, height: 3)),
                    with: .color(color.opacity(intensity))
                )
            }
        }
        .frame(width: 21, height: 15)
    }
}

private struct DynamicIslandView: View {
    private enum IslandTab: Equatable { case codex, music, time }
    @ObservedObject private var island = DynamicIslandService.shared
    @ObservedObject private var reminders = TimeReminderService.shared
    @ObservedObject private var codex = CodexIslandService.shared
    @State private var selectedTab: IslandTab = .codex
    @State private var quickMinutes = 25
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
            } else if island.showsExpandedContent {
                codexContent
                    .transition(.opacity)
            } else {
                compactContent
                    .transition(.opacity)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(width: island.expanded ? island.expandedSize.width : island.compactWidth,
               height: island.expanded ? island.expandedSize.height : island.compactHeight)
        .background(Color.black, in: UnevenRoundedRectangle(topLeadingRadius: 0,
                                                            bottomLeadingRadius: 8,
                                                            bottomTrailingRadius: 8,
                                                            topTrailingRadius: 0,
                                                            style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if island.showsExpandedContent { modeSwitcher }
        }
        .animation(.smooth(duration: 0.36), value: island.expanded)
        .animation(.easeInOut(duration: 0.18), value: island.showsExpandedContent)
        .animation(.easeInOut(duration: 0.16), value: selectedTab)
        .onChange(of: reminders.presentation) { oldValue, newValue in
            if oldValue == nil, newValue != nil { selectedTab = .time }
            if newValue == nil { selectedTab = .codex }
        }
        .onChange(of: island.timeReminderActivationID) { _, _ in selectedTab = .time }
        .onChange(of: island.codexActivationID) { _, _ in selectedTab = .codex }
        .onChange(of: selectedTab) { _, value in island.setCodexTabActive(value == .codex) }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            Spacer()
            Button { selectedTab = .codex } label: {
                Label("Codex", systemImage: "terminal.fill").labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .font(.system(size: 11)).frame(width: 25, height: 22).background(selectedTab == .codex ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            Button { selectedTab = .music } label: {
                Label("音乐", systemImage: "music.note").labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .font(.system(size: 11)).frame(width: 25, height: 22).background(selectedTab == .music ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            Button { selectedTab = .time } label: {
                Label("时间", systemImage: "timer").labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .font(.system(size: 11)).frame(width: 25, height: 22).background(selectedTab == .time ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
        }.padding(.top, 6).padding(.trailing, 10)
    }

    private var timeSetupContent: some View {
        VStack(spacing: 11) {
            HStack {
                Image(systemName: "timer").font(.system(size: 28)).foregroundStyle(.orange)
                Text("设置时间").font(.headline)
                Spacer()
            }
            HStack(spacing: 14) {
                Button { quickMinutes = max(1, quickMinutes - (quickMinutes <= 10 ? 1 : 5)) } label: { Image(systemName: "minus.circle.fill") }
                Text("\(quickMinutes) 分钟").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(width: 178, alignment: .center)
                Button { quickMinutes = min(240, quickMinutes + (quickMinutes < 10 ? 1 : 5)) } label: { Image(systemName: "plus.circle.fill") }
            }
            HStack(spacing: 12) {
                Button("开始倒计时") { reminders.startCountdown(title: "倒计时", minutes: quickMinutes) }
                    .buttonStyle(.borderedProminent).tint(.orange)
                Button("开始专注") { reminders.startFocus(minutes: quickMinutes) }
                    .buttonStyle(.bordered)
            }
        }.padding(.horizontal, 32).padding(.top, 23).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var compactContent: some View {
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
                Text("\(codex.sessions.count) 个会话")
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
                           subtitle: "即将开始", progress: nil) {
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
            if lhs.status == .waiting, rhs.status != .waiting { return true }
            if rhs.status == .waiting, lhs.status != .waiting { return false }
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
                HStack(spacing: 16) {
                    Image(systemName: "terminal.fill").font(.system(size: 25)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 54, height: 54).background(.blue.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(codex.enabled ? "Codex" : "Codex 集成未启用").font(.system(size: 17, weight: .semibold))
                        Text(codex.enabled ? "暂无运行中的任务" : "可在灵动岛设置中启用 Codex Hooks")
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Button("打开 Codex") { codex.openCodex() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 32).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func codexSessionRow(_ session: CodexIslandSession, fontSize: Double) -> some View {
        Button { codex.openCodex(session) } label: {
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
                codexSessionTrailing(session)
            }
        }
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
        VStack(spacing: 8) {
            HStack(spacing: 16) {
            if let track = island.nowPlaying {
                artwork(for: track)
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title ?? "正在播放")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text([track.artist, track.album].compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
            } else {
                Rectangle()
                    .fill(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Apple Music").font(.system(size: 16, weight: .semibold))
                    Text(island.musicLaunchInProgress ? "正在打开 Apple Music…" : "点击播放以打开音乐并继续播放")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 20) {
                if island.nowPlaying != nil {
                    Button(action: { DynamicIslandService.sendMediaKey(20) }) { Image(systemName: "backward.fill") }
                }
                Button(action: { island.togglePlayback() }) {
                    if island.musicLaunchInProgress {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: island.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                if island.nowPlaying != nil {
                    Button(action: { DynamicIslandService.sendMediaKey(19) }) { Image(systemName: "forward.fill") }
                }
            }
            .font(.system(size: 17, weight: .semibold))
            }
            if island.duration > 0 {
                HStack(spacing: 8) {
                    Text(time(island.elapsedTime)).monospacedDigit()
                    ContrastSlider(value: Binding(get: { island.elapsedTime }, set: { island.seek(to: $0) }),
                                   range: 0...max(island.duration, 1))
                    Text(time(island.duration)).monospacedDigit()
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.82))
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.caption)
                ContrastSlider(value: Binding(get: { island.outputVolume }, set: { island.setVolume($0) }),
                               range: 0...1)
                Text("\(Int((island.outputVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
            }
            .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 10)
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
