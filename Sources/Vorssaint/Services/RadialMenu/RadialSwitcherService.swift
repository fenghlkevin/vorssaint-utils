// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// A separate, dynamic wheel for running apps and their windows. It does not
/// share state, shortcuts or preferences with the existing app switcher.
final class RadialSwitcherService: ObservableObject {
    static let shared = RadialSwitcherService()

    enum Entry: Identifiable {
        case app(NSRunningApplication)
        case window(SwitcherItem)
        case tab(RadialBrowserTab)
        case favorite(RadialFavorite)
        case action(RadialAppAction)
        case back
        case next

        var id: String {
            switch self {
            case .app(let app): return "app:\(app.processIdentifier)"
            case .window(let item): return item.id
            case .tab(let tab): return "tab:\(tab.pid):\(tab.id)"
            case .favorite(let favorite): return "favorite:\(favorite.bundleID)"
            case .action(let action): return "action:\(action.id)"
            case .back: return "back"
            case .next: return "next"
            }
        }

        var title: String {
            switch self {
            case .app(let app): return app.localizedName ?? "App"
            case .window(let item): return item.displayTitle
            case .tab(let tab): return tab.title
            case .favorite(let favorite): return favorite.name
            case .action(let action): return action.name
            case .back: return "返回"
            case .next: return "更多"
            }
        }

        var icon: NSImage? {
            switch self {
            case .app(let app): return app.icon
            case .window(let item): return item.appIcon
            case .tab: return nil
            case .favorite(let favorite):
                return favorite.resolvedURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            case .action: return nil
            case .back, .next: return nil
            }
        }

        var symbol: String {
            switch self {
            case .app: return "app"
            case .window: return "macwindow"
            case .tab: return "rectangle.on.rectangle"
            case .favorite: return "star.fill"
            case .action: return "command"
            case .back: return "arrow.uturn.backward"
            case .next: return "arrow.right"
            }
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var heading = "应用"
    @Published private(set) var highlightedIndex: Int? {
        didSet {
            if let index = highlightedIndex, entries.indices.contains(index),
               case .app(let app) = entries[index] { centerApplication = app }
        }
    }
    @Published private(set) var centerApplication: NSRunningApplication?
    private var columnHoverAnchor = NSPoint.zero
    @Published private(set) var columnFocusOnChildren = false
    @Published private(set) var childMode = "windows"
    @Published private(set) var registrationFailed = false
    @Published private(set) var message: String?
    @Published private(set) var currentPage = 0
    @Published private(set) var previewTitle = ""
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var styles = RadialSwitcherStorage.styles()

    var usesColumns: Bool {
        UserDefaults.standard.string(forKey: DefaultsKey.radialSwitcherPresentation) == "columns"
            && actionTarget == nil && !favoritesVisible
    }
    var columnApps: [NSRunningApplication] {
        appEntries.compactMap { if case .app(let app) = $0 { return app }; return nil }
    }

    func selectColumnApp(_ app: NSRunningApplication) {
        columnFocusOnChildren = false
        guard selectedApp?.processIdentifier != app.processIdentifier || !showingWindows else {
            highlightedIndex = nil
            return
        }
        centerApplication = app
        showChildren(for: app)
        highlightedIndex = nil
    }

    func hoverColumnApp(_ app: NSRunningApplication) {
        guard acceptColumnHover() else { return }
        selectColumnApp(app)
    }

    private func acceptColumnHover() -> Bool {
        let pointer = NSEvent.mouseLocation
        guard hypot(pointer.x - columnHoverAnchor.x, pointer.y - columnHoverAnchor.y) > 3 else { return false }
        columnHoverAnchor = pointer
        return true
    }

    func highlightColumnChild(_ index: Int) {
        guard entries.indices.contains(index), acceptColumnHover() else { return }
        columnFocusOnChildren = true
        highlightedIndex = index
    }

    private let actionHotkey = QuickToolHotkey(id: 1751)
    private var panel: NSPanel?
    private var previewPanel: NSPanel?
    private var monitors: [Any] = []
    private var appEntries: [Entry] = []
    private var allEntries: [Entry] = []
    private var page = 0
    @Published private(set) var showingWindows = false
    @Published private(set) var selectedApp: NSRunningApplication?
    private var actionTarget: NSRunningApplication?
    private var invocationApp: NSRunningApplication?
    private var favoritesVisible = false
    private var favoritesPinned = false
    private var savedFavoritesEntries: [Entry] = []
    private var savedFavoritesHeading = "应用"
    private var savedFavoritesPage = 0
    private var recentPIDs: [pid_t] = []
    private var optionDown = false
    private var optionDownAt: TimeInterval?
    private var firstOptionUpAt: TimeInterval?
    private var activationObserver: NSObjectProtocol?
    private var requestID = 0
    private init() {
        if let app = NSWorkspace.shared.frontmostApplication {
            recentPIDs = [app.processIdentifier]
        }
        actionHotkey.onPress = { [weak self] in self?.presentActions() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recentPIDs.removeAll { $0 == app.processIdentifier }
            self?.recentPIDs.insert(app.processIdentifier, at: 0)
            if let self, self.recentPIDs.count > 128 { self.recentPIDs.removeLast() }
        }
    }

    func syncWithPreferences() {
        let enabled = AppFeature.radialSwitcher.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.radialSwitcherEnabled)
        let shortcut = GlobalShortcut(storageValue:
            UserDefaults.standard.string(forKey: DefaultsKey.radialSwitcherShortcut) ?? "")
            ?? .radialSwitcherDefault
        registrationFailed = enabled && !Permissions.shared.accessibility
        RadialSwitcherKeyboard.configure(enabled: enabled && Permissions.shared.accessibility,
            shortcut: shortcut,
            holdToSelect: UserDefaults.standard.bool(forKey: DefaultsKey.radialSwitcherHoldToSelect))
        AppSwitcher.shared.syncWithPreferences()
        if let actionShortcut = UserDefaults.standard.string(forKey: DefaultsKey.radialSwitcherActionShortcut),
           let key = GlobalShortcut(storageValue: actionShortcut), key != shortcut {
            _ = actionHotkey.sync(enabled: enabled, shortcut: key)
        } else {
            actionHotkey.unregister()
        }
        if !enabled { dismiss() }
        RadialTrackpadService.shared.sync()
    }

    func present() {
        RadialSwitcherActivation.cancel()
        guard AppFeature.radialSwitcher.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.radialSwitcherEnabled) else { return }
        invocationApp = NSWorkspace.shared.frontmostApplication
        centerApplication = invocationApp
        // Capture the source even when activation notifications have not arrived yet.
        // Freeze the resulting order until the next invocation.
        if let app = invocationApp {
            recentPIDs.removeAll { $0 == app.processIdentifier }
            recentPIDs.insert(app.processIdentifier, at: 0)
        }
        let rules = RadialSwitcherStorage.appRules()
        let sortByName = UserDefaults.standard.bool(forKey: DefaultsKey.radialSwitcherSortByName)
        appEntries = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated
                && rules[$0.bundleIdentifier ?? ""] != "hidden" }
            .sorted {
                if !sortByName {
                    let left = recentPIDs.firstIndex(of: $0.processIdentifier) ?? Int.max
                    let right = recentPIDs.firstIndex(of: $1.processIdentifier) ?? Int.max
                    if left != right { return left < right }
                }
                return ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
            .map(Entry.app)
        showingWindows = false
        selectedApp = nil
        actionTarget = nil
        favoritesVisible = false
        favoritesPinned = false
        message = nil
        heading = "应用"
        allEntries = appEntries
        page = 0
        updatePage()
        guard !entries.isEmpty else { return }
        let panel = ensurePanel()
        let pointer = NSEvent.mouseLocation
        columnHoverAnchor = pointer
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = presentationSize
        panel.setContentSize(size)
        let origin = CGPoint(x: min(max(pointer.x - size.width / 2, frame.minX), frame.maxX - size.width),
                             y: min(max(pointer.y - size.height / 2, frame.minY), frame.maxY - size.height))
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        installMonitors()
        if usesColumns, let app = columnApps.first(where: { $0.processIdentifier == invocationApp?.processIdentifier }) ?? columnApps.first {
            selectColumnApp(app)
        }
        if let id = invocationApp?.bundleIdentifier,
           UserDefaults.standard.stringArray(forKey: DefaultsKey.radialSwitcherActionModeApps)?.contains(id) == true,
           let invocationApp {
            showActions(for: invocationApp)
        }
    }

    func dismiss() {
        RadialSwitcherKeyboard.cancel()
        requestID += 1
        optionDown = false
        optionDownAt = nil
        firstOptionUpAt = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        previewPanel?.orderOut(nil)
        previewImage = nil
        highlightedIndex = nil
    }

    func select(_ index: Int) {
        guard panel?.isVisible == true, entries.indices.contains(index) else { return }
        switch entries[index] {
        case .app(let app):
            activate(app)
        case .window(let item):
            guard let app = NSRunningApplication(processIdentifier: item.pid) else { dismiss(); return }
            let sourcePID = invocationApp?.processIdentifier
            dismiss()
            RadialSwitcherActivation.activate(app: app, window: item, sourcePID: sourcePID)
        case .tab(let tab):
            dismiss()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try RadialBrowserEvents(pid: tab.pid, budget: 3).activate(tab)
                    DispatchQueue.main.async {
                        if let app = NSRunningApplication(processIdentifier: tab.pid) {
                            RadialSwitcherActivation.activate(app: app, window: nil, sourcePID: nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async { NSSound.beep() }
                }
            }
        case .favorite(let favorite):
            guard let url = favorite.resolvedURL else { NSSound.beep(); return }
            dismiss()
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { DispatchQueue.main.async { NSSound.beep() } }
            }
        case .action(let action):
            guard let app = actionTarget, let shortcut = action.usableShortcut else { return }
            let focus = RadialActionExecutor.capture(for: app)
            dismiss()
            if let focus { RadialActionExecutor.execute(shortcut, focus: focus) }
            else { NSSound.beep() }
        case .back:
            requestID += 1
            message = nil
            if favoritesVisible { restoreFavorites(); return }
            if actionTarget != nil { restoreApplications(); return }
            restoreApplications()
        case .next:
            page += 1
            updatePage()
        }
    }

    func close(_ entry: Entry) {
        switch entry {
        case .window(let item):
            WindowActivator.closeWindowIncludingHiddenState(item) { [weak self] success in
                guard let self else { return }
                if success, let app = self.selectedApp { self.selectAppWindows(app) }
                else { NSSound.beep() }
            }
        case .tab(let tab):
            DispatchQueue.global(qos: .userInitiated).async {
                let success = (try? RadialBrowserEvents(pid: tab.pid, budget: 3).close(tab)) != nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if success, let app = self.selectedApp { self.loadTabs(for: app) }
                    else { NSSound.beep() }
                }
            }
        default: break
        }
    }

    func displayTitle(for entry: Entry) -> String {
        guard let key = RadialSwitcherStorage.styleKey(for: entry),
              let name = styles[key]?.name, !name.isEmpty else { return entry.title }
        return name
    }

    func color(for entry: Entry) -> Color? {
        guard let key = RadialSwitcherStorage.styleKey(for: entry),
              let name = styles[key]?.color, !name.isEmpty else { return nil }
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        default: return nil
        }
    }

    func editStyle(_ entry: Entry) {
        guard let key = RadialSwitcherStorage.styleKey(for: entry) else { return }
        let current = styles[key] ?? .init(name: "", color: "")
        let alert = NSAlert()
        alert.messageText = "编辑名称与颜色"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let name = NSTextField(string: current.name)
        name.placeholderString = entry.title
        let color = NSPopUpButton()
        let colorNames = ["默认", "红", "橙", "黄", "绿", "薄荷", "青绿", "青", "蓝", "靛", "紫", "粉", "棕"]
        color.addItems(withTitles: colorNames)
        color.selectItem(at: RadialSwitcherStorage.colors.firstIndex(of: current.color) ?? 0)
        let stack = NSStackView(views: [name, color])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = String(name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let chosen = RadialSwitcherStorage.colors[color.indexOfSelectedItem]
        if trimmed.isEmpty && chosen.isEmpty { styles.removeValue(forKey: key) }
        else { styles[key] = .init(name: trimmed, color: chosen) }
        if styles.count > 2048 {
            styles = Dictionary(styles.prefix(2048).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(styles), forKey: DefaultsKey.radialSwitcherStyles)
    }

    func quit(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let id = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        dismiss()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let current = NSRunningApplication(processIdentifier: pid),
                  current.bundleIdentifier == id else { return }
            _ = current.terminate()
        }
    }

    func quitIfDragged(_ entry: Entry, distance: CGFloat) {
        guard case .app(let app) = entry, let panel, distance >= 6 else { return }
        let point = NSEvent.mouseLocation
        let radius = hypot(point.x - panel.frame.midX, point.y - panel.frame.midY)
        guard radius > RadialSwitcherLayout.wheelDiameter / 2 + 18 else { return }
        quit(app)
    }

    func activate(_ app: NSRunningApplication) {
        let sourcePID = invocationApp?.processIdentifier
        let window = realWindows(for: app).first
        dismiss()
        RadialSwitcherActivation.activate(app: app, window: window, sourcePID: sourcePID)
    }

    func showChildren(for app: NSRunningApplication) {
        guard panel?.isVisible == true else { return }
        selectedApp = app
        showingWindows = true
        if RadialSwitcherStorage.appRules()[app.bundleIdentifier ?? ""] == "tabs",
           RadialBrowserEvents.supports(app.bundleIdentifier) {
            loadTabs(for: app)
        } else { selectAppWindows(app) }
    }

    var centerApp: NSRunningApplication? { showingWindows ? selectedApp : centerApplication }
    var supportsChildTabs: Bool { showingWindows && RadialBrowserEvents.supports(selectedApp?.bundleIdentifier) }
    var childItemCount: Int { allEntries.count }

    func centerAction() {
        if showingWindows { restoreApplications() }
        else if let app = centerApplication { showChildren(for: app) }
    }

    func switchChildMode(_ mode: String) {
        guard showingWindows, let app = selectedApp, mode != childMode else { return }
        if mode == "tabs", RadialBrowserEvents.supports(app.bundleIdentifier) { loadTabs(for: app) }
        else { selectAppWindows(app) }
    }

    func newWindow(_ app: NSRunningApplication) {
        dismiss()
        RadialSwitcherWindowCreator.create(for: app)
    }

    func point(at location: CGPoint) {
        guard !usesColumns, let panel else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let next = RadialMenuGeometry.highlightedIndex(
            dx: location.x - center.x, dyUp: location.y - center.y,
            deadZoneRadius: RadialSwitcherLayout.deadZoneRadius, itemCount: entries.count)
        if next == nil { return } // Keep selection while moving to the center controls.
        if next != highlightedIndex {
            highlightedIndex = next
            updatePreview()
        }
    }

    func activatePointer() {
        point(at: NSEvent.mouseLocation)
        if let highlightedIndex { select(highlightedIndex) }
        else { dismiss() }
    }

    private func toggle() {
        if panel?.isVisible == true { dismiss() } else { present() }
    }

    func toggleFromTrackpad() { toggle() }

    func keyboardStep(first: Bool, reverse: Bool) {
        columnHoverAnchor = NSEvent.mouseLocation
        if UserDefaults.standard.string(forKey: DefaultsKey.radialSwitcherPresentation) == "columns" {
            if first || panel?.isVisible != true { present() }
            if usesColumns && !columnFocusOnChildren {
                let apps = columnApps
                guard !apps.isEmpty else { return }
                let current = apps.firstIndex { $0.processIdentifier == selectedApp?.processIdentifier }
                let next = ((current ?? (reverse ? 0 : -1)) + (reverse ? -1 : 1) + apps.count) % apps.count
                selectColumnApp(apps[next])
                return
            }
        }
        if first || panel?.isVisible != true {
            present()
            if let current = entries.firstIndex(where: {
                if case .app(let app) = $0 { return app.processIdentifier == invocationApp?.processIdentifier }
                return false
            }) { highlightedIndex = current }
        }
        guard !allEntries.isEmpty else { return }
        let pageSize = effectivePageSize
        let current = highlightedIndex.map { page * pageSize + $0 }
        let next = ((current ?? (reverse ? 0 : -1)) + (reverse ? -1 : 1) + allEntries.count) % allEntries.count
        page = next / pageSize
        updatePage()
        highlightedIndex = next % pageSize
        updatePreview()
    }

    func commitKeyboardSelection() {
        guard panel?.isVisible == true else { return }
        if usesColumns, !columnFocusOnChildren, let app = selectedApp { activate(app); return }
        guard let index = highlightedIndex, entries.indices.contains(index) else {
            if let selectedApp { activate(selectedApp) } else { dismiss() }
            return
        }
        // Modifier release always finishes; opening a child ring is explicit.
        switch entries[index] {
        case .app(let app): activate(app)
        case .back, .next:
            if let selectedApp { activate(selectedApp) } else { dismiss() }
        default: select(index)
        }
    }

    func openKeyboardChildren() {
        if usesColumns {
            columnFocusOnChildren.toggle()
            highlightedIndex = columnFocusOnChildren && !entries.isEmpty ? 0 : nil
            return
        }
        if showingWindows { restoreApplications(); return }
        guard let index = highlightedIndex, entries.indices.contains(index),
              case .app(let app) = entries[index] else { return }
        showChildren(for: app)
        if panel?.isVisible == true { highlightedIndex = entries.isEmpty ? nil : 0; updatePreview() }
    }

    private func realWindows(for app: NSRunningApplication) -> [SwitcherItem] {
        WindowEnumerator.listWindows(for: app.processIdentifier, maximumCount: 64)
            .filter { !$0.isAppEntry && (UserDefaults.standard.bool(forKey: DefaultsKey.radialSwitcherIncludeMinimized)
                || !$0.isMinimized) }
    }

    private func selectAppWindows(_ app: NSRunningApplication, windows: [SwitcherItem]? = nil) {
        requestID += 1
        childMode = "windows"
        message = nil
        let windows = windows ?? realWindows(for: app)
        guard usesColumns || !windows.isEmpty || RadialBrowserEvents.supports(app.bundleIdentifier) else {
            activate(app)
            return
        }
        showingWindows = true
        selectedApp = app
        heading = app.localizedName ?? "窗口"
        allEntries = windows.map(Entry.window)
        if windows.isEmpty { message = "没有可切换的窗口" }
        page = 0
        updatePage()
    }

    private func loadTabs(for app: NSRunningApplication) {
        requestID += 1
        let currentRequest = requestID
        message = "正在读取标签页…"
        childMode = "tabs"
        heading = app.localizedName ?? "标签页"
        allEntries = []
        entries = []
        highlightedIndex = nil
        previewPanel?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.requestID == currentRequest, self.allEntries.isEmpty else { return }
            self.message = "正在等待浏览器或系统自动化授权，可返回后重试。"
        }
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[RadialBrowserTab], Error> = Result {
                let permission = RadialBrowserEvents.permission(pid: pid, ask: true)
                guard permission == noErr else { throw RadialBrowserError.permission }
                return try RadialBrowserEvents(pid: pid).list()
            }
            DispatchQueue.main.async {
                guard self.requestID == currentRequest else { return }
                switch result {
                case .success(let tabs):
                    self.allEntries = tabs.map(Entry.tab)
                    self.message = tabs.isEmpty ? "没有打开的标签页" : nil
                    self.page = 0
                    if tabs.isEmpty { self.entries = [] }
                    else { self.updatePage() }
                case .failure(let error):
                    self.allEntries = []
                    self.entries = []
                    self.message = error.localizedDescription
                }
            }
        }
    }

    private var effectivePageSize: Int {
        if usesColumns { return max(allEntries.count, 1) }
        let preferred = actionTarget != nil ? 6
            : (showingWindows ? UserDefaults.standard.integer(forKey: DefaultsKey.radialSwitcherWindowPageSize)
                : UserDefaults.standard.integer(forKey: DefaultsKey.radialSwitcherAppPageSize))
        return min(max(preferred, 2), showingWindows ? 8 : 24)
    }

    private func updatePage() {
        guard !allEntries.isEmpty else { entries = []; return }
        let pageSize = effectivePageSize
        let start = page * pageSize
        guard start < allEntries.count else { page = 0; updatePage(); return }
        var visible = Array(allEntries[start..<min(start + pageSize, allEntries.count)])
        if start + pageSize < allEntries.count { visible.append(.next) }
        if !showingWindows && (page > 0 || actionTarget != nil || favoritesVisible) { visible.append(.back) }
        entries = visible
        currentPage = page
        highlightedIndex = nil
        previewPanel?.orderOut(nil)
    }

    private func updatePreview() {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.radialSwitcherPreviews),
              let index = highlightedIndex, entries.indices.contains(index) else {
            previewPanel?.orderOut(nil)
            return
        }
        switch entries[index] {
        case .window(let item):
            previewTitle = displayTitle(for: .window(item))
            previewImage = item.windowID.flatMap { WindowPreviewProvider.shared.cachedPreview(for: $0) }
            showPreviewPanel()
            guard let id = item.windowID, !item.isMinimized, Permissions.shared.screenRecording else { return }
            WindowPreviewProvider.shared.refreshPreviews(for: [item], maxPixelSize: 900) { [weak self] windowID, image in
                guard let self, windowID == id,
                      let current = self.highlightedIndex,
                      self.entries.indices.contains(current), self.entries[current].id == item.id else { return }
                self.previewImage = image
            }
        case .tab(let tab):
            previewTitle = displayTitle(for: .tab(tab))
            previewImage = nil
            showPreviewPanel()
        default:
            previewPanel?.orderOut(nil)
        }
    }

    private func showPreviewPanel() {
        guard let wheel = panel, let screen = wheel.screen else { return }
        let preview = ensurePreviewPanel()
        let width: CGFloat = 420
        let height: CGFloat = 320
        let frame = screen.visibleFrame
        let right = wheel.frame.maxX + 12
        let x = right + width <= frame.maxX ? right : max(frame.minX, wheel.frame.minX - width - 12)
        let y = min(max(wheel.frame.midY - height / 2, frame.minY), frame.maxY - height)
        preview.setFrameOrigin(CGPoint(x: x, y: y))
        preview.orderFront(nil)
    }

    private func ensurePreviewPanel() -> NSPanel {
        if let previewPanel { return previewPanel }
        let preview = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                              defer: false)
        preview.level = .statusBar
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.hasShadow = true
        preview.ignoresMouseEvents = true
        preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        preview.contentViewController = NSHostingController(rootView: RadialSwitcherPreviewView())
        previewPanel = preview
        return preview
    }

    private func restoreApplications() {
        requestID += 1
        message = nil
        favoritesVisible = false
        favoritesPinned = false
        actionTarget = nil
        showingWindows = false
        selectedApp = nil
        heading = "应用"
        allEntries = appEntries
        page = 0
        updatePage()
    }

    func showFavorites(pinned: Bool = false) {
        guard !showingWindows, !favoritesVisible else { return }
        let favorites = RadialSwitcherStorage.favorites().map(Entry.favorite)
        guard !favorites.isEmpty else { return }
        savedFavoritesEntries = allEntries
        savedFavoritesHeading = heading
        savedFavoritesPage = page
        favoritesVisible = true
        favoritesPinned = pinned
        heading = "常用应用"
        allEntries = favorites
        page = 0
        updatePage()
    }

    func toggleFavoritesPinned() {
        if favoritesVisible { restoreFavorites() }
        else { showFavorites(pinned: true) }
    }

    private func restoreFavorites() {
        guard favoritesVisible else { return }
        favoritesVisible = false
        favoritesPinned = false
        allEntries = savedFavoritesEntries
        heading = savedFavoritesHeading
        page = savedFavoritesPage
        updatePage()
    }

    func presentActions() {
        guard AppFeature.radialSwitcher.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.radialSwitcherEnabled),
              let app = NSWorkspace.shared.frontmostApplication
        else { return }
        present()
        showActions(for: app)
    }

    private func showActions(for app: NSRunningApplication) {
        guard let profile = RadialSwitcherStorage.actions()
            .first(where: { $0.bundleID == app.bundleIdentifier }) else { return }
        let actions = profile.actions.filter { $0.usableShortcut != nil }.map(Entry.action)
        guard !actions.isEmpty else { return }
        actionTarget = app
        heading = profile.appName
        allEntries = actions
        page = 0
        updatePage()
    }

    private func toggleActionMode() {
        guard !showingWindows, !favoritesVisible else { return }
        guard let id = invocationApp?.bundleIdentifier else { return }
        var selected = Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.radialSwitcherActionModeApps) ?? [])
        if actionTarget != nil {
            selected.remove(id)
            restoreApplications()
        } else if let invocationApp {
            showActions(for: invocationApp)
            if actionTarget != nil { selected.insert(id) }
        }
        UserDefaults.standard.set(Array(selected), forKey: DefaultsKey.radialSwitcherActionModeApps)
    }

    private func handleOption(_ event: NSEvent) {
        guard event.keyCode == 58 else { return } // left Option only
        let now = ProcessInfo.processInfo.systemUptime
        if event.modifierFlags.contains(.option) {
            optionDown = true
            optionDownAt = now
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.optionDown, self.panel?.isVisible == true,
                      !self.favoritesVisible else { return }
                self.showFavorites()
            }
        } else {
            optionDown = false
            if favoritesVisible && !favoritesPinned { restoreFavorites() }
            guard let down = optionDownAt, now - down <= 0.15 else {
                firstOptionUpAt = nil
                optionDownAt = nil
                return
            }
            optionDownAt = nil
            if let first = firstOptionUpAt, now - first <= 0.35 {
                firstOptionUpAt = nil
                toggleActionMode()
            } else { firstOptionUpAt = now }
        }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if self.usesColumns {
                switch Int(event.keyCode) {
                case 53: self.dismiss(); return nil
                case 48, 125, 126:
                    self.keyboardStep(first: false, reverse: event.keyCode == 126 || event.modifierFlags.contains(.shift))
                    return nil
                case 50, 123, 124: self.openKeyboardChildren(); return nil
                case 36, 76: self.commitKeyboardSelection(); return nil
                default: break
                }
            }
            switch Int(event.keyCode) {
            case 53: self.dismiss(); return nil // Escape
            case 48 where event.modifierFlags.contains(.shift): // Shift-Tab
                self.highlightedIndex = self.entries.isEmpty ? nil
                    : ((self.highlightedIndex ?? 0) + self.entries.count - 1) % self.entries.count
                self.updatePreview()
                return nil
            case 48, 124, 125: // Tab, right, down
                self.highlightedIndex = self.entries.isEmpty ? nil
                    : ((self.highlightedIndex ?? -1) + 1) % self.entries.count
                self.updatePreview()
                return nil
            case 123, 126: // Left, up
                self.highlightedIndex = self.entries.isEmpty ? nil
                    : ((self.highlightedIndex ?? 0) + self.entries.count - 1) % self.entries.count
                self.updatePreview()
                return nil
            case 50: // Backtick switches between app and window/tab levels.
                self.openKeyboardChildren()
                return nil
            case 36, 76:
                if let index = self.highlightedIndex { self.select(index) }
                return nil
            default:
                if let digit = event.charactersIgnoringModifiers?.first?.wholeNumberValue,
                   (1...self.entries.count).contains(digit) {
                    self.select(digit - 1)
                    return nil
                }
                return event
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.point(at: NSEvent.mouseLocation)
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            guard let self else { return event }
            self.handleOption(event)
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown], handler: { [weak self] event in
            guard let self else { return }
            if event.type == .mouseMoved { self.point(at: NSEvent.mouseLocation) }
            else if self.panel?.frame.contains(NSEvent.mouseLocation) == false { self.dismiss() }
        }) { monitors.append(monitor) }
    }

    private final class WheelPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var presentationSize: CGSize {
        UserDefaults.standard.string(forKey: DefaultsKey.radialSwitcherPresentation) == "columns"
            ? CGSize(width: 720, height: 560)
            : CGSize(width: RadialSwitcherLayout.panelSize, height: RadialSwitcherLayout.panelSize)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let size = RadialSwitcherLayout.panelSize
        let panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.title = "环形切换器"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentViewController = NSHostingController(rootView: RadialSwitcherPresentationView())
        self.panel = panel
        return panel
    }
}
