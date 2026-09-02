// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

private enum InlineSpecialTool: String { case text, note, magnifier, watermark }
private enum InlineFontDesign: String, CaseIterable { case system, serif, monospaced }

private extension ScreenshotSupport.LineStyle {
    var inlineDashPattern: [CGFloat] {
        switch self {
        case .solid: return []
        case .dashed: return [8, 5]
        case .dotted: return [2, 4]
        }
    }
}

private enum InlineCapturePreferenceKey {
    static let prefix = "screenshot.inlineEditor."
    static let color = prefix + "color"
    static let stroke = prefix + "stroke"
    static let lineStyle = prefix + "lineStyle"
    static let filled = prefix + "filled"
    static let arrowStyle = prefix + "arrowStyle"
    static let mosaicMode = prefix + "mosaicMode"
    static let magnifierShape = prefix + "magnifierShape"
    static let magnifierZoom = prefix + "magnifierZoom"
    static let fontDesign = prefix + "fontDesign"
    static let bold = prefix + "bold"
    static let fontSize = prefix + "fontSize"
    static let counterColor = prefix + "counterColor"
    static let highlightColor = prefix + "highlightColor"
}

private struct InlineSpecialMark: Identifiable {
    let id: UUID
    let kind: InlineSpecialTool
    var start: CGPoint
    var end: CGPoint
    var text: String
    var color: ScreenshotSupport.ColorID
    var stroke: ScreenshotSupport.StrokeID
    var lineStyle: ScreenshotSupport.LineStyle = .solid
    var magnifierShape: ScreenshotSupport.MagnifierShape
    var magnifierZoom: CGFloat
    var fontDesign: InlineFontDesign
    var bold: Bool
    var fontSize: CGFloat = 18
    var textWidth: CGFloat = 188
}

private func inlineTextRect(_ mark: InlineSpecialMark) -> CGRect {
    let size = mark.fontSize
    let font = inlineCaptureFont(design: mark.fontDesign, bold: mark.bold, size: size)
    let width = max(120, mark.textWidth)
    let measured = (mark.text.isEmpty ? " " : mark.text).boundingRect(
        with: CGSize(width: width - 16, height: 2_000),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font])
    return CGRect(origin: mark.start,
                  size: CGSize(width: width, height: max(28, ceil(measured.height) + 12)))
}

private func inlineNoteRect(_ mark: InlineSpecialMark) -> CGRect {
    let font = inlineCaptureFont(design: mark.fontDesign, bold: mark.bold, size: mark.fontSize)
    let contentWidth = max(80, mark.textWidth - 34)
    let measured = (mark.text.isEmpty ? " " : mark.text).boundingRect(
        with: CGSize(width: contentWidth, height: 2_000),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font])
    let height = max(40, ceil(measured.height) + 20)
    return CGRect(x: mark.end.x - 4, y: mark.end.y - 18,
                  width: max(120, mark.textWidth), height: height)
}

private struct InlineCapturePayload {
    var annotations: [ScreenshotSupport.Annotation]
    var specialMarks: [InlineSpecialMark]
    var watermarkText: String
    var watermarkColor: ScreenshotSupport.ColorID
    var watermarkStroke: ScreenshotSupport.StrokeID
    var watermarkOpacity: CGFloat
    var watermarkAngle: CGFloat
    var watermarkScale: CGFloat
    var watermarkSpacing: CGFloat
    var fontDesign: InlineFontDesign
    var bold: Bool
}

private func inlineCaptureFont(design: InlineFontDesign, bold: Bool, size: CGFloat) -> NSFont {
    let weight: NSFont.Weight = bold ? .bold : .regular
    switch design {
    case .system: return NSFont.systemFont(ofSize: size, weight: weight)
    case .monospaced: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    case .serif:
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// The capture surface: one borderless panel per screen, above everything,
/// where the user drags a region, clicks a window or confirms a full screen.
///
/// With freeze on (the default) every display is photographed first and the
/// panels show that still image while the area is chosen. With freeze off the
/// panels are transparent and pixels are captured at confirmation time.
///
/// More than one feature picks an area this way, so the surface says what the
/// area is for and only one session is ever on screen.
final class ScreenshotSelectionController {

    struct Capture {
        enum Delivery { case standard, copy, saveToDownloads }
        let image: CGImage
        /// Pixels per point of the source display, for 1x export math.
        let scale: CGFloat
        /// The captured area in Cocoa global coordinates.
        let anchorRect: CGRect
        let delivery: Delivery
        var trace: ScreenshotCaptureTrace?

        init(image: CGImage, scale: CGFloat, anchorRect: CGRect,
             delivery: Delivery = .standard) {
            self.image = image
            self.scale = scale
            self.anchorRect = anchorRect
            self.delivery = delivery
        }
    }

    /// What the caller wants out of the same gesture. The screenshot tool
    /// wants pixels; the recorder wants to know WHERE, and takes its own
    /// pixels afterwards, for as long as the person keeps recording.
    enum Mode {
        case image
        case geometry
        case color
    }

    enum Outcome {
        case captured(Capture)
        case region(RecorderSupport.Region)
        case scrollingRegion(RecorderSupport.Region)
        case color(NSColor)
        case cancelled
        case failed
    }

    private var panels: [ScreenshotOverlayPanel] = []

    var protectedWindowIDs: Set<CGWindowID> {
        Set(panels.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
    }

    /// The overlays are part of the capture, so they stay excluded even when
    /// the session is not registered anywhere yet.
    private var captureExcludedWindowIDs: Set<CGWindowID> {
        otherProtectedWindowIDs().union(protectedWindowIDs)
    }
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var completion: ((Outcome) -> Void)?
    private let freeze: Bool
    private let includePointer: Bool
    private let showLastRegion: Bool
    private let hideVorssaintWindows: Bool
    private let otherProtectedWindowIDs: () -> Set<CGWindowID>
    private let baseMode: Mode
    private let supportsScrollingCapture: Bool
    private let screenCaptureOptions: ScreenCaptureSelectionOptions?
    fileprivate let requiresDraggedRegion: Bool
    private var finished = false
    private var editingTrace: ScreenshotCaptureTrace?
    /// Read by the overlays so a late event finds a session that is over.
    fileprivate var isOver: Bool { finished }
    fileprivate var spaceIsDown = false
    fileprivate var selectionInProgress = false {
        didSet { panels.forEach { $0.overlayView.refreshGuideVisibility() } }
    }
    fileprivate var scrollingCaptureEnabled = false {
        didSet {
            panels.forEach {
                $0.overlayView.refreshCaptureGuide()
                $0.overlayView.needsDisplay = true
            }
        }
    }
    fileprivate var offersScrollingCapture: Bool {
        supportsScrollingCapture && activeTool == .screenshot && activeMode == .image
    }
    fileprivate var acceptsWindowClick: Bool {
        activeMode != .color && !requiresDraggedRegion && !scrollingCaptureEnabled
    }
    fileprivate var isPickingColor: Bool { activeMode == .color }
    fileprivate var offersInlineScreenshotEditing: Bool {
        activeMode == .image && activeTool != .text && !scrollingCaptureEnabled
    }
    fileprivate var loupeEnabled = false {
        didSet { panels.forEach { $0.overlayView.refreshPointerState() } }
    }
    fileprivate var loupeZoom: CGFloat = 1 {
        didSet { panels.forEach { $0.overlayView.needsDisplay = true } }
    }

    /// The last confirmed region, per display, so R repeats it instantly.
    private static var lastRegion: (displayID: CGDirectDisplayID, viewRect: CGRect)?

    /// True while a session owns the screen. Two surfaces at once would stack
    /// dim over dim and split the keyboard between them, so whichever feature
    /// asks second is turned away.
    private(set) static var isSessionOnScreen = false

    private let strings = FeatureStrings.screenshot(L10n.shared.language)
    /// Named at the head of the hint bar so the surface never leaves the
    /// person guessing what the area they are about to pick is for.
    private let purpose: String?

    init(freeze: Bool,
         includePointer: Bool,
         showLastRegion: Bool,
         hideVorssaintWindows: Bool = true,
         protectedWindowIDs: @escaping () -> Set<CGWindowID> = { [] },
         purpose: String? = nil,
         mode: Mode = .image,
         supportsScrollingCapture: Bool = false,
         requiresDraggedRegion: Bool = false,
         screenCaptureOptions: ScreenCaptureSelectionOptions? = nil) {
        self.freeze = freeze
        self.includePointer = includePointer
        self.showLastRegion = showLastRegion
        self.hideVorssaintWindows = hideVorssaintWindows
        self.otherProtectedWindowIDs = protectedWindowIDs
        self.purpose = purpose
        self.baseMode = mode
        self.supportsScrollingCapture = supportsScrollingCapture
        self.requiresDraggedRegion = requiresDraggedRegion
        self.screenCaptureOptions = screenCaptureOptions
    }

    private var activeTool: ScreenCaptureTool? { screenCaptureOptions?.selectedTool }

    private var activeMode: Mode {
        switch activeTool {
        case .recording: return .geometry
        case .color: return .color
        case .screenshot, .text: return .image
        case .none: return baseMode
        }
    }

    func begin(completion: @escaping (Outcome) -> Void) {
        Self.isSessionOnScreen = true
        self.completion = completion
        screenCaptureOptions?.onSelectionChange = { [weak self] in
            self?.screenCaptureToolDidChange()
        }
        if freeze {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let images = await ScreenshotCaptureEngine.captureAllDisplays(
                    includePointer: self.includePointer,
                    hideVorssaintWindows: self.hideVorssaintWindows,
                    protectedWindowIDs: self.captureExcludedWindowIDs)
                guard !images.isEmpty else {
                    self.finish(.failed)
                    return
                }
                self.present(frozenImages: images)
            }
        } else {
            present(frozenImages: [:])
        }
    }

    /// Reopens an already captured image in the same on-screen editor used
    /// immediately after selecting a region.  Keeping this route here means
    /// the quick-preview Edit action cannot drift onto the older, separate
    /// annotation window with a different tool set.
    func beginEditing(capture: Capture, completion: @escaping (Outcome) -> Void) {
        capture.trace?.event("inline-editor-input", image: capture.image, details: "scale=\(capture.scale) anchor=\(capture.anchorRect)")
        editingTrace = capture.trace
        Self.isSessionOnScreen = true
        self.completion = completion
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(capture.anchorRect) })
                ?? NSScreen.main else {
            finish(.failed)
            return
        }
        let panel = ScreenshotOverlayPanel(screen: screen,
                                           frozenImage: capture.image,
                                           windows: [],
                                           controller: self,
                                           strings: strings,
                                           purpose: nil,
                                           screenCaptureOptions: nil,
                                           editingCapture: capture)
        panels = [panel]
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
        loupeEnabled = false
        panel.overlayView.beginExistingCaptureEditing()
    }

    private func present(frozenImages: [CGDirectDisplayID: CGImage]) {
        guard !finished else { return }
        let pickable = ScreenshotCaptureEngine.pickableWindows(
            hideVorssaintWindows: hideVorssaintWindows,
            protectedWindowIDs: captureExcludedWindowIDs)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0

        for screen in NSScreen.screens {
            let displayID = screen.displayID
            if freeze, frozenImages[displayID] == nil { continue }
            let windows = pickable.map { entry -> ScreenshotSupport.PickableWindow in
                let cocoa = ScreenshotSupport.cocoaRect(fromWindowServer: entry.bounds,
                                                        mainScreenHeight: mainHeight)
                let viewRect = ScreenshotSupport.flippedViewRect(fromCocoa: cocoa,
                                                                 screenFrame: screen.frame)
                return ScreenshotSupport.PickableWindow(windowID: entry.id, frame: viewRect)
            }.filter { $0.frame.intersects(CGRect(origin: .zero, size: screen.frame.size)) }

            let panel = ScreenshotOverlayPanel(screen: screen,
                                               frozenImage: frozenImages[displayID],
                                               windows: windows,
                                               controller: self,
                                               strings: strings,
                                               purpose: purpose,
                                               screenCaptureOptions: screenCaptureOptions)
            if showLastRegion, let last = Self.lastRegion, last.displayID == displayID {
                panel.overlayView.ghostRect = last.viewRect
            }
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        guard !panels.isEmpty else {
            finish(.failed)
            return
        }
        keyPanelUnderMouse()?.makeKey()
        installKeyMonitor()
        loupeEnabled = isPickingColor || activeMode == .image
        if loupeEnabled, !freeze { loadLiveLoupeImages() }
        panels.forEach { $0.overlayView.refreshPointerState() }
        NSCursor.arrow.set()
    }

    private func screenCaptureToolDidChange() {
        scrollingCaptureEnabled = false
        loupeEnabled = isPickingColor || activeMode == .image
        if loupeEnabled, !freeze { loadLiveLoupeImages() }
        panels.forEach { $0.overlayView.captureToolDidChange() }
        if selectionInProgress { selectionInProgress = false }
    }

    /// Live selection stays transparent, but the loupe still needs source
    /// pixels. Capture them once after the overlays exist; ScreenCaptureKit
    /// excludes this app's own panels, so the screen itself remains live.
    private func loadLiveLoupeImages() {
        let hideWindows = hideVorssaintWindows
        let excludedIDs = captureExcludedWindowIDs
        Task { @MainActor [weak self] in
            let images = await ScreenshotCaptureEngine.captureAllDisplays(
                includePointer: false,
                hideVorssaintWindows: hideWindows,
                protectedWindowIDs: excludedIDs)
            guard let self, !self.finished else { return }
            for panel in self.panels {
                panel.overlayView.updateLoupeImage(images[panel.displayID])
            }
        }
    }

    fileprivate func ensureInlineSourceImages() { loadLiveLoupeImages() }

    /// Once a display owns the inline editor, the other display overlays have
    /// finished their job. Removing them immediately lets video, animation and
    /// every other live surface continue normally on those displays while the
    /// selected display remains in edit mode.
    fileprivate func beginInlineEditing(on selectedPanel: ScreenshotOverlayPanel) {
        for panel in panels where panel !== selectedPanel { panel.orderOut(nil) }
        selectedPanel.enterInteractiveEditing()
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window is ScreenshotOverlayPanel else { return event }
            // NSTextField edits through the window's shared NSTextView field
            // editor. Passing those events through is what makes both the
            // toolbar input and the on-canvas text box actually typeable.
            if event.window?.firstResponder is NSTextView { return event }
            if event.type == .keyUp {
                if event.keyCode == UInt16(kVK_Space) { self.spaceIsDown = false }
                return nil
            }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.finish(.cancelled)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if self.acceptsWindowClick {
                    self.captureFullDisplayUnderMouse()
                }
            case kVK_Space:
                if let panel = self.panelUnderMouse(), panel.overlayView.isDragging {
                    // Holding Space moves the in-progress selection.
                    self.spaceIsDown = true
                }
            case kVK_Delete, kVK_ForwardDelete:
                self.panelUnderMouse()?.overlayView.deleteSelectedEditorItem()
            case kVK_ANSI_R:
                self.repeatLastRegion()
            case _ where self.selectCaptureTool(for: event):
                break
            case _ where Self.isLoupeKey(event):
                self.toggleLoupe()
            default:
                break
            }
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            self?.finish(.cancelled)
        }
    }

    private func selectCaptureTool(for event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let tool = ScreenCaptureTool.matchingShortcut(event.charactersIgnoringModifiers),
              let screenCaptureOptions,
              screenCaptureOptions.availableTools.contains(tool)
        else { return false }
        screenCaptureOptions.select(tool)
        return true
    }

    /// The loupe toggle follows the typed character, with the physical slot
    /// as a fallback: the Z key sits elsewhere on some keyboard layouts and
    /// the localized hints promise the letter itself.
    private static func isLoupeKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        if let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty {
            return typed == "z"
        }
        return Int(event.keyCode) == kVK_ANSI_Z
    }

    fileprivate func toggleScrollingCapture() {
        guard offersScrollingCapture else { return }
        scrollingCaptureEnabled.toggle()
        panels.forEach { $0.overlayView.refreshPointerState() }
    }

    private func toggleLoupe() {
        loupeEnabled.toggle()
        // Live mode has no frozen shot to sample. Pixels are fetched only
        // when the loupe actually turns on, and fresh each time, so it
        // magnifies what is on screen now instead of the session's opening
        // frame and idle sessions never pay for a capture.
        if loupeEnabled, !freeze {
            loadLiveLoupeImages()
        }
    }

    fileprivate func adjustLoupeZoom(by scrollDelta: CGFloat) {
        loupeZoom = ScreenshotSupport.captureLoupeZoom(loupeZoom, adjustedBy: scrollDelta)
    }

    private func panelUnderMouse() -> ScreenshotOverlayPanel? {
        let location = NSEvent.mouseLocation
        return panels.first { $0.screenFrame.contains(location) } ?? panels.first
    }

    private func keyPanelUnderMouse() -> ScreenshotOverlayPanel? {
        panelUnderMouse()
    }

    // MARK: - Confirmations (called by the views)

    /// The surfaces stop answering the pointer the instant a picture starts
    /// being taken. They are either about to leave the screen or already gone,
    /// and the rest of the gesture must not begin a second capture.
    private func markCapturePending() {
        panels.forEach { $0.overlayView.isCapturePending = true }
    }

    /// The picked area as the recorder needs it: whole even pixels of the
    /// source display, plus the same area in Cocoa points so a panel can be
    /// anchored to it. The point rectangle is derived from the SNAPPED pixels,
    /// so what gets recorded and what the person was shown never disagree.
    private func region(fromView viewRect: CGRect,
                        on panel: ScreenshotOverlayPanel,
                        windowID: CGWindowID?) -> RecorderSupport.Region {
        let displayPixels = CGRect(origin: .zero, size: panel.pixelSize)
        let raw = ScreenshotSupport.imagePixelRect(fromView: viewRect,
                                                   viewSize: panel.screenFrame.size,
                                                   imageSize: panel.pixelSize)
        let snapped = RecorderSupport.snappedPixelRect(raw, in: displayPixels)
        let scale = panel.pixelScale > 0 ? panel.pixelScale : 1
        let snappedView = CGRect(x: snapped.origin.x / scale,
                                 y: snapped.origin.y / scale,
                                 width: snapped.width / scale,
                                 height: snapped.height / scale)
        return RecorderSupport.Region(
            displayID: panel.displayID,
            windowID: windowID,
            pixelRect: snapped,
            anchorRect: ScreenshotSupport.cocoaRect(fromFlippedView: snappedView,
                                                    screenFrame: panel.screenFrame),
            scale: scale)
    }

    fileprivate func confirmRegion(_ viewRect: CGRect,
                                   payload: InlineCapturePayload? = nil,
                                   delivery: Capture.Delivery = .standard,
                                   on panel: ScreenshotOverlayPanel) {
        guard viewRect.width >= 1, viewRect.height >= 1 else { return }
        guard activeMode != .color else { return }
        markCapturePending()
        Self.lastRegion = (panel.displayID, viewRect)
        if activeMode == .geometry {
            finish(.region(region(fromView: viewRect, on: panel, windowID: nil)))
            return
        }
        if scrollingCaptureEnabled {
            finish(.scrollingRegion(region(fromView: viewRect, on: panel, windowID: nil)))
            return
        }
        let pixelRect = panel.imagePixelRect(fromView: viewRect)
        editingTrace?.event("editor-confirm", image: panel.frozenImage,
                            details: "selection=\(viewRect) crop=\(pixelRect) scale=\(panel.pixelScale)")
        if let frozen = panel.frozenImage {
            guard let cropped = frozen.cropping(to: pixelRect) else {
                finish(.failed)
                return
            }
            let rendered = payload.flatMap {
                renderInlinePayload($0, relativeTo: viewRect,
                                    scale: panel.pixelScale, on: cropped)
            } ?? cropped
            finish(.captured(Capture(
                image: rendered,
                scale: panel.pixelScale,
                anchorRect: panel.editingAnchorRect ?? ScreenshotSupport.cocoaRect(
                    fromFlippedView: viewRect,
                    screenFrame: panel.screenFrame),
                delivery: delivery)))
        } else {
            captureLive(displayID: panel.displayID,
                        pixelRect: pixelRect,
                        scale: panel.pixelScale,
                        payload: payload,
                        annotationViewRect: viewRect,
                        delivery: delivery,
                        anchorRect: ScreenshotSupport.cocoaRect(
                            fromFlippedView: viewRect,
                            screenFrame: panel.screenFrame))
        }
    }

    fileprivate func confirmWindow(_ windowID: CGWindowID,
                                   frame: CGRect,
                                   on panel: ScreenshotOverlayPanel) {
        guard activeMode != .color else { return }
        markCapturePending()
        if activeMode == .geometry {
            finish(.region(region(fromView: frame, on: panel, windowID: windowID)))
            return
        }
        if scrollingCaptureEnabled {
            finish(.scrollingRegion(region(fromView: frame, on: panel, windowID: windowID)))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let image = await ScreenshotCaptureEngine.captureWindow(
                windowID, scale: panel.pixelScale) else {
                self.finish(.failed)
                return
            }
            self.finish(.captured(Capture(
                image: image,
                scale: panel.pixelScale,
                anchorRect: ScreenshotSupport.cocoaRect(
                    fromFlippedView: frame,
                    screenFrame: panel.screenFrame))))
        }
    }

    private func captureFullDisplayUnderMouse() {
        guard activeMode != .color else { return }
        guard let panel = panelUnderMouse() else { return }
        markCapturePending()
        if activeMode == .geometry {
            let whole = CGRect(origin: .zero, size: panel.screenFrame.size)
            finish(.region(region(fromView: whole, on: panel, windowID: nil)))
            return
        }
        if let frozen = panel.frozenImage {
            finish(.captured(Capture(image: frozen,
                                     scale: panel.pixelScale,
                                     anchorRect: panel.screenFrame)))
        } else {
            captureLive(displayID: panel.displayID,
                        pixelRect: nil,
                        scale: panel.pixelScale,
                        anchorRect: panel.screenFrame)
        }
    }

    private func repeatLastRegion() {
        guard activeMode != .color else { return }
        guard let last = Self.lastRegion,
              let panel = panels.first(where: { $0.displayID == last.displayID })
        else { return }
        confirmRegion(last.viewRect, on: panel)
    }

    fileprivate func confirmColor(at viewPoint: CGPoint, on panel: ScreenshotOverlayPanel) {
        guard activeMode == .color,
              let image = panel.frozenImage ?? panel.overlayView.loupeImage else { return }
        let point = ScreenshotSupport.imagePixelPoint(
            fromView: viewPoint,
            viewSize: panel.screenFrame.size,
            imageSize: CGSize(width: image.width, height: image.height))
        let x = min(max(Int(point.x.rounded(.down)), 0), image.width - 1)
        let y = min(max(Int(point.y.rounded(.down)), 0), image.height - 1)
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let color = NSBitmapImageRep(cgImage: pixel).colorAt(x: 0, y: 0)
        else {
            finish(.failed)
            return
        }
        markCapturePending()
        finish(.color(color))
    }

    /// Live-mode confirmation: the panels leave the screen, the display is
    /// photographed, and only then does the session end. The brief hide is
    /// what the capture must not contain.
    private func captureLive(displayID: CGDirectDisplayID,
                             pixelRect: CGRect?,
                             scale: CGFloat,
                             payload: InlineCapturePayload? = nil,
                             annotationViewRect: CGRect? = nil,
                             delivery: Capture.Delivery = .standard,
                             anchorRect: CGRect) {
        panels.forEach { $0.orderOut(nil) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard var image = await ScreenshotCaptureEngine.captureDisplay(
                displayID,
                includePointer: self.includePointer,
                hideVorssaintWindows: self.hideVorssaintWindows,
                protectedWindowIDs: self.captureExcludedWindowIDs)
            else {
                self.finish(.failed)
                return
            }
            if let pixelRect {
                let clamped = ScreenshotSupport.clamp(
                    pixelRect,
                    to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let cropped = image.cropping(to: clamped) else {
                    self.finish(.failed)
                    return
                }
                image = cropped
            }
            if let annotationViewRect, let payload {
                image = self.renderInlinePayload(payload,
                                                 relativeTo: annotationViewRect,
                                                 scale: scale,
                                                 on: image) ?? image
            }
            self.finish(.captured(Capture(image: image,
                                          scale: scale,
                                          anchorRect: anchorRect,
                                          delivery: delivery)))
        }
    }

    private func renderInlinePayload(_ payload: InlineCapturePayload,
                                     relativeTo viewRect: CGRect,
                                     scale: CGFloat,
                                     on image: CGImage) -> CGImage? {
        let transformed = payload.annotations.map {
            ScreenshotSupport.captureLocalAnnotation($0, selection: viewRect, scale: scale)
        }
        let pixelated = transformed.contains { $0.tool == .pixelate }
            ? ScreenshotRenderer.pixelatedImage(from: image) : nil
        guard let base = ScreenshotRenderer.renderExport(
            baseImage: image,
            annotations: transformed,
            pixelated: pixelated,
            scale: scale,
            annotationShadowsEnabled: false,
            style: ScreenshotSupport.BackdropStyle(),
            fill: .none,
            downscaleTo1x: false) else { return nil }
        return renderInlineSpecials(payload, relativeTo: viewRect, scale: scale, on: base)
    }

    private func renderInlineSpecials(_ payload: InlineCapturePayload,
                                      relativeTo viewRect: CGRect,
                                      scale: CGFloat,
                                      on image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - viewRect.minX) * scale,
                    y: (point.y - viewRect.minY) * scale)
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        for mark in payload.specialMarks {
            let start = local(mark.start), end = local(mark.end)
            switch mark.kind {
            case .text:
                let textRect = inlineTextRect(mark)
                let localRect = CGRect(x: (textRect.minX - viewRect.minX) * scale,
                                       y: (textRect.minY - viewRect.minY) * scale,
                                       width: textRect.width * scale,
                                       height: textRect.height * scale)
                context.saveGState()
                context.setStrokeColor(ScreenshotRenderer.color(mark.color, alpha: 0.92))
                context.setLineWidth(max(scale, mark.stroke.width * scale * 0.55))
                context.addPath(CGPath(roundedRect: localRect.insetBy(dx: scale * 0.5,
                                                                     dy: scale * 0.5),
                                       cornerWidth: 7 * scale, cornerHeight: 7 * scale,
                                       transform: nil))
                context.strokePath()
                context.restoreGState()
                drawExportText(mark.text, in: localRect, color: mark.color,
                               fontSize: mark.fontSize, scale: scale,
                               design: mark.fontDesign, bold: mark.bold)
            case .note:
                context.setStrokeColor(ScreenshotRenderer.color(mark.color))
                context.setLineWidth(mark.stroke.width * scale)
                context.setLineDash(phase: 0,
                                    lengths: mark.lineStyle.inlineDashPattern.map { $0 * scale })
                context.move(to: start); context.addLine(to: end); context.strokePath()
                let noteRect = inlineNoteRect(mark)
                let box = CGRect(x: (noteRect.minX - viewRect.minX) * scale,
                                 y: (noteRect.minY - viewRect.minY) * scale,
                                 width: noteRect.width * scale,
                                 height: noteRect.height * scale)
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: 3 * scale),
                                  blur: 8 * scale,
                                  color: CGColor(gray: 0, alpha: 0.22))
                let noteFill = ScreenshotRenderer.nsColor(mark.color)
                    .blended(withFraction: 0.72, of: .white) ?? .white
                context.setFillColor(noteFill.cgColor)
                context.addPath(CGPath(roundedRect: box, cornerWidth: 8 * scale,
                                       cornerHeight: 8 * scale, transform: nil))
                context.fillPath()
                context.restoreGState()
                context.setStrokeColor(ScreenshotRenderer.color(mark.color, alpha: 0.82))
                context.setLineWidth(max(scale, mark.stroke.width * scale * 0.65))
                context.addPath(CGPath(roundedRect: box, cornerWidth: 8 * scale,
                                       cornerHeight: 8 * scale, transform: nil))
                context.strokePath()
                context.setFillColor(ScreenshotRenderer.color(mark.color))
                context.fillEllipse(in: CGRect(x: box.minX + 8 * scale,
                                               y: box.midY - 3 * scale,
                                               width: 6 * scale, height: 6 * scale))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: inlineCaptureFont(design: mark.fontDesign, bold: mark.bold,
                                             size: mark.fontSize * scale),
                    .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
                ]
                mark.text.draw(in: CGRect(x: box.minX + 21 * scale,
                                          y: box.minY + 9 * scale,
                                          width: box.width - 29 * scale,
                                          height: box.height - 15 * scale),
                               withAttributes: attributes)
            case .magnifier:
                let radius = max(68 * scale, hypot(end.x - start.x, end.y - start.y))
                let frame = CGRect(x: start.x - radius, y: start.y - radius,
                                   width: radius * 2, height: radius * 2)
                let path = mark.magnifierShape == .circle
                    ? CGPath(ellipseIn: frame, transform: nil)
                    : CGPath(roundedRect: frame, cornerWidth: 10 * scale,
                             cornerHeight: 10 * scale, transform: nil)
                let side = max(12, radius * 2 / max(mark.magnifierZoom, 1))
                let source = ScreenshotSupport.cropLoupeSampleRect(
                    around: start, imageSize: CGSize(width: width, height: height), sideLength: side)
                if let sample = image.cropping(to: source) {
                    context.saveGState()
                    context.addPath(path); context.clip()
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.draw(sample, in: CGRect(x: frame.minX,
                                                    y: CGFloat(height) - frame.maxY,
                                                    width: frame.width, height: frame.height))
                    context.restoreGState()
                }
                context.setStrokeColor(ScreenshotRenderer.color(mark.color))
                context.setLineWidth(mark.stroke.width * scale)
                context.addPath(path); context.strokePath()
            case .watermark:
                break
            }
        }

        if !payload.watermarkText.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: inlineCaptureFont(design: payload.fontDesign, bold: payload.bold,
                                         size: 18 * scale * payload.watermarkScale),
                .foregroundColor: ScreenshotRenderer.nsColor(payload.watermarkColor)
                    .withAlphaComponent(payload.watermarkOpacity),
            ]
            for y in stride(from: CGFloat(0), through: CGFloat(height),
                            by: 76 * scale * payload.watermarkSpacing) {
                for x in stride(from: -40 * scale, through: CGFloat(width),
                                by: 190 * scale * payload.watermarkSpacing) {
                    context.saveGState()
                    context.translateBy(x: x, y: y)
                    context.rotate(by: payload.watermarkAngle * .pi / 180)
                    payload.watermarkText.draw(at: .zero, withAttributes: attributes)
                    context.restoreGState()
                }
            }
        }
        return context.makeImage()
    }

    private func drawExportText(_ text: String, in rect: CGRect,
                                color: ScreenshotSupport.ColorID,
                                fontSize: CGFloat,
                                scale: CGFloat,
                                design: InlineFontDesign,
                                bold: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: inlineCaptureFont(design: design, bold: bold,
                                     size: fontSize * scale),
            .foregroundColor: ScreenshotRenderer.nsColor(color),
        ]
        text.draw(in: rect.insetBy(dx: 8 * scale, dy: 6 * scale),
                  withAttributes: attributes)
    }

    func cancel() {
        finish(.cancelled)
    }

    deinit {
        // A session that goes away without ending would otherwise leave the
        // screen marked as taken and every capture feature dead until the app
        // is restarted. The wrong flag is always the one that lets a capture
        // start, never the one that blocks it.
        if !finished { Self.isSessionOnScreen = false }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        var outcome = outcome
        if case .captured(var capture) = outcome, let trace = editingTrace {
            capture.trace = trace
            trace.event("editor-output", image: capture.image, details: "scale=\(capture.scale)")
            outcome = .captured(capture)
        }
        finished = true
        Self.isSessionOnScreen = false
        screenCaptureOptions?.onSelectionChange = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        // A gesture can still have events on the way, so the surfaces are made
        // inert before they leave the screen: whatever arrives after this
        // point finds nothing left to act on.
        markCapturePending()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        let completion = completion
        self.completion = nil
        completion?(outcome)
    }

    fileprivate func cancelInlineEditing() { finish(.cancelled) }
}

// MARK: - Panel

/// Full-screen borderless panel for one display. Never activates the app;
/// becomes key only so Esc and friends arrive.
private final class ScreenshotOverlayPanel: NSPanel {
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    let frozenImage: CGImage?
    let pixelScale: CGFloat
    /// Image rectangle when an existing capture is reopened.  The panel stays
    /// full-screen so the identical toolbar has room above or below the image.
    let editingSourceRect: CGRect?
    let editingAnchorRect: CGRect?
    private(set) var overlayViewStorage: ScreenshotOverlayView!

    var overlayView: ScreenshotOverlayView { overlayViewStorage }

    var frozenImageSize: CGSize? {
        frozenImage.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Display size in pixels, for live-mode crop math.
    var pixelSize: CGSize {
        CGSize(width: screenFrame.width * pixelScale, height: screenFrame.height * pixelScale)
    }

    init(screen: NSScreen,
         frozenImage: CGImage?,
         windows: [ScreenshotSupport.PickableWindow],
         controller: ScreenshotSelectionController,
         strings: ScreenshotFeatureStrings,
         purpose: String?,
         screenCaptureOptions: ScreenCaptureSelectionOptions?,
         editingCapture: ScreenshotSelectionController.Capture? = nil) {
        screenFrame = screen.frame
        displayID = screen.displayID
        self.frozenImage = frozenImage
        if let capture = editingCapture {
            let natural = CGSize(width: CGFloat(capture.image.width) / max(capture.scale, 1),
                                 height: CGFloat(capture.image.height) / max(capture.scale, 1))
            let available = screen.frame.insetBy(dx: 28, dy: 116)
            let factor = min(1, min(available.width / max(natural.width, 1),
                                    available.height / max(natural.height, 1)))
            let size = CGSize(width: natural.width * factor, height: natural.height * factor)
            editingSourceRect = CGRect(x: (screen.frame.width - size.width) / 2,
                                       y: (screen.frame.height - size.height) / 2 - 18,
                                       width: size.width, height: size.height)
            // Existing captures are fitted into the available screen area. A
            // scrolling capture can therefore be displayed much smaller than
            // its original point size. Annotation/export coordinates must use
            // the ratio between the original pixels and that fitted rectangle,
            // not the display's backing scale (normally 2x). Otherwise confirm
            // crops only the first screen-sized slice of an otherwise correct
            // long preview image.
            pixelScale = CGFloat(capture.image.width) / max(size.width, 1)
            editingAnchorRect = capture.anchorRect
        } else {
            pixelScale = screen.backingScaleFactor
            editingSourceRect = nil
            editingAnchorRect = nil
        }
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isReleasedWhenClosed = false
        isOpaque = frozenImage != nil
        backgroundColor = frozenImage == nil ? .clear : .black
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true

        // The frozen still sits in its own view UNDER the chrome: a backing
        // layer configured before the view joins a window can lose its
        // contents, and the chrome's dim must paint over the image anyway.
        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        if let frozenImage {
            let displayedRect = editingSourceRect.map {
                CGRect(x: $0.minX, y: container.bounds.height - $0.maxY,
                       width: $0.width, height: $0.height)
            } ?? container.bounds
            let imageView = NSImageView(frame: displayedRect)
            imageView.image = NSImage(cgImage: frozenImage, size: screen.frame.size)
            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]
            container.addSubview(imageView)
        }
        let view = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                         frozenImage: frozenImage,
                                         loupeImage: frozenImage,
                                         windows: windows,
                                         controller: controller,
                                         panel: self,
                                         strings: strings,
                                         purpose: purpose,
                                         screenCaptureOptions: screenCaptureOptions,
                                         initialEditingRect: editingSourceRect)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        overlayViewStorage = view
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    func imagePixelRect(fromView viewRect: CGRect) -> CGRect {
        if let source = editingSourceRect, let imageSize = frozenImageSize {
            let relative = CGRect(x: viewRect.minX - source.minX,
                                  y: viewRect.minY - source.minY,
                                  width: viewRect.width, height: viewRect.height)
            return ScreenshotSupport.imagePixelRect(fromView: relative,
                                                    viewSize: source.size,
                                                    imageSize: imageSize)
        }
        return ScreenshotSupport.imagePixelRect(
            fromView: viewRect,
            viewSize: screenFrame.size,
            imageSize: frozenImageSize ?? pixelSize)
    }

    func enterInteractiveEditing() {
        // A nonactivating key panel can own the NSTextView first responder.
        // Activating the app here switches Stage Manager to Settings behind
        // the frozen selection and changes the later live capture.
        becomesKeyOnlyIfNeeded = false
        makeKeyAndOrderFront(nil)
        makeFirstResponder(overlayView)
    }
}

// MARK: - View

/// Draws the frozen background, the dim, the selection, window highlights
/// and the magnifier; owns all mouse interaction. Flipped so
/// geometry matches image pixels (top-left origin) with no sign juggling.
private final class ScreenshotOverlayView: NSView, NSTextViewDelegate {
    private let frozenImage: CGImage?
    fileprivate var loupeImage: CGImage?
    private var inlinePixelatedImage: CGImage?
    private let windows: [ScreenshotSupport.PickableWindow]
    /// Both are held weakly on purpose. The session hands its result over
    /// after the panels leave the screen, so the controller is already gone
    /// while the window server still delivers the tail of a gesture here.
    private weak var controller: ScreenshotSelectionController?
    private weak var panel: ScreenshotOverlayPanel?
    private let strings: ScreenshotFeatureStrings
    private let purpose: String?
    private let screenCaptureOptions: ScreenCaptureSelectionOptions?
    private let guideHost: PassThroughHostingView<CaptureGuideView>
    private lazy var editorState = InlineCaptureEditorState()
    private lazy var inlineToolbar = NSHostingView(rootView: InlineCaptureToolbar(
        state: editorState,
        canScrollCapture: controller?.offersScrollingCapture ?? false,
        scrollCapture: { [weak self] in self?.beginInlineScrollingCapture() },
        cancel: { [weak self] in self?.controller?.cancelInlineEditing() },
        save: { [weak self] in self?.confirmInlineSelection(delivery: .saveToDownloads) },
        confirm: { [weak self] in self?.confirmInlineSelection(delivery: .copy) }))
    private var editorObservation: AnyCancellable?

    private var dragOrigin: CGPoint?
    private var lastDragPoint: CGPoint = .zero
    private var selection: CGRect = .zero
    private var hoverPoint: CGPoint = .zero
    private var hoveredWindow: ScreenshotSupport.PickableWindow?
    private var inlineEditing = false
    private var resizeHandle: ScreenshotSupport.Handle?
    private var resizeOrigin: CGRect?
    private var moveOrigin: CGRect?
    private var inlineTextEditor: NSScrollView?
    private weak var inlineTextView: NSTextView?
    private var inlineTextPoint: CGPoint?
    private var inlineTextMarkID: UUID?
    private var inlineTextKind: InlineSpecialTool = .text
    var ghostRect: CGRect?
    var isCapturePending = false {
        didSet {
            refreshGuideVisibility()
            needsDisplay = true
        }
    }

    var isDragging: Bool { dragOrigin != nil }

    /// A surface whose session is over answers nothing, so the rest of a
    /// gesture can neither reach a controller that is gone nor start a second
    /// capture behind the one already running.
    private var acceptsPointerInput: Bool {
        ScreenshotSupport.selectionAcceptsPointerInput(
            sessionIsOver: controller?.isOver ?? true,
            capturePending: isCapturePending)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect,
         frozenImage: CGImage?,
         loupeImage: CGImage?,
         windows: [ScreenshotSupport.PickableWindow],
         controller: ScreenshotSelectionController,
         panel: ScreenshotOverlayPanel,
         strings: ScreenshotFeatureStrings,
         purpose: String?,
         screenCaptureOptions: ScreenCaptureSelectionOptions?,
         initialEditingRect: CGRect? = nil) {
        self.frozenImage = frozenImage
        self.loupeImage = loupeImage
        self.windows = windows
        self.controller = controller
        self.panel = panel
        self.strings = strings
        self.purpose = purpose
        self.screenCaptureOptions = screenCaptureOptions
        let host = PassThroughHostingView(rootView: CaptureGuideView(
            strings: strings,
            purpose: purpose,
            offersScrollingCapture: controller.offersScrollingCapture,
            requiresDraggedRegion: controller.requiresDraggedRegion,
            scrollingCaptureEnabled: controller.scrollingCaptureEnabled,
            screenCaptureOptions: screenCaptureOptions,
            toggleScrollingCapture: { [weak controller] in
                controller?.toggleScrollingCapture()
            }))
        host.passesThrough = screenCaptureOptions == nil
        guideHost = host
        super.init(frame: frame)
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                                .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        addSubview(guideHost)
        inlineToolbar.isHidden = true
        addSubview(inlineToolbar)
        editorObservation = editorState.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                self.needsLayout = true
                self.window?.invalidateCursorRects(for: self)
            }
        }
        refreshGuideVisibility()
        if let initialEditingRect {
            selection = initialEditingRect
        }
    }

    func beginExistingCaptureEditing() {
        guard selection.width >= 2, selection.height >= 2,
              let controller, let panel else { return }
        inlineEditing = true
        controller.beginInlineEditing(on: panel)
        controller.selectionInProgress = false
        guideHost.isHidden = true
        inlineToolbar.isHidden = false
        needsLayout = true
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        let cursor: NSCursor
        if inlineEditing, editorState.specialTool == .text || editorState.specialTool == .note {
            cursor = .iBeam
        } else if inlineEditing, !editorState.hasActiveTool {
            cursor = .openHand
        } else {
            cursor = .arrow
        }
        addCursorRect(bounds, cursor: cursor)
        guard inlineEditing else { return }
        for handle in ScreenshotSupport.Handle.allCases {
            let point = handle.position(in: selection)
            addCursorRect(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
                          cursor: resizeCursor(for: handle))
        }
        if let id = editorState.selectedAnnotationID,
           let mark = editorState.annotations.first(where: { $0.id == id }) {
            if mark.points.count >= 2 {
                let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
                if let minX = xs.min(), let maxX = xs.max(),
                   let minY = ys.min(), let maxY = ys.max() {
                    addCursorRect(CGRect(x: minX, y: minY,
                                         width: max(18, maxX - minX),
                                         height: max(18, maxY - minY)).insetBy(dx: -6, dy: -6),
                                  cursor: .openHand)
                }
                for point in [mark.points[0], mark.points[1]] {
                    addCursorRect(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
                                  cursor: Self.diagonalDownCursor)
                }
            } else {
                if mark.rect.width > 16, mark.rect.height > 16 {
                    addCursorRect(mark.rect.insetBy(dx: 7, dy: 7), cursor: .openHand)
                }
                for handle in ScreenshotSupport.Handle.allCases {
                    let point = handle.position(in: mark.rect)
                    addCursorRect(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
                                  cursor: resizeCursor(for: handle))
                }
            }
        }
        if let id = editorState.selectedSpecialID,
           let mark = editorState.specialMarks.first(where: { $0.id == id }) {
            let specialRect: CGRect?
            switch mark.kind {
            case .text: specialRect = inlineTextRect(mark)
            case .note: specialRect = inlineNoteRect(mark)
            case .magnifier:
                let radius = max(68, hypot(mark.end.x - mark.start.x,
                                           mark.end.y - mark.start.y))
                specialRect = CGRect(x: mark.start.x - radius, y: mark.start.y - radius,
                                     width: radius * 2, height: radius * 2)
            case .watermark: specialRect = nil
            }
            if let specialRect {
                addCursorRect(specialRect.insetBy(dx: 7, dy: 7), cursor: .openHand)
            }
            if mark.kind == .magnifier, let specialRect {
                for handle in ScreenshotSupport.Handle.allCases {
                    let point = handle.position(in: specialRect)
                    addCursorRect(CGRect(x: point.x - 8, y: point.y - 8,
                                         width: 16, height: 16),
                                  cursor: resizeCursor(for: handle))
                }
            } else if mark.kind == .text, let specialRect {
                for point in [CGPoint(x: specialRect.minX, y: specialRect.midY),
                              CGPoint(x: specialRect.maxX, y: specialRect.midY)] {
                    addCursorRect(CGRect(x: point.x - 8, y: point.y - 8,
                                         width: 16, height: 16), cursor: .resizeLeftRight)
                }
            } else if mark.kind == .note {
                let rect = inlineNoteRect(mark)
                let point = CGPoint(x: rect.maxX, y: rect.midY)
                addCursorRect(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
                              cursor: .resizeLeftRight)
            }
        }
    }

    private static let diagonalDownCursor = diagonalCursor(
        symbol: "arrow.up.left.and.arrow.down.right")
    private static let diagonalUpCursor = diagonalCursor(
        symbol: "arrow.up.right.and.arrow.down.left")

    private static func diagonalCursor(symbol: String) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)) ?? NSImage(size: NSSize(width: 18, height: 18))
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2,
                                                       y: image.size.height / 2))
    }

    private func resizeCursor(for handle: ScreenshotSupport.Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return Self.diagonalDownCursor
        case .topRight, .bottomLeft: return Self.diagonalUpCursor
        }
    }

    override func layout() {
        super.layout()
        let width = min(screenCaptureOptions == nil ? 680 : 620,
                        max(280, bounds.width - 32))
        let height: CGFloat = screenCaptureOptions != nil
            ? 146
            : 72
        guideHost.frame = CGRect(x: bounds.midX - width / 2,
                                 y: bounds.maxY - height - 32,
                                 width: width,
                                 height: height)
        let toolbarWidth = min(1_180, max(520, bounds.width - 24))
        let toolbarHeight: CGFloat = InlineCaptureToolbar.contentHeight(hasSettings: editorState.hasSettings) + 8
        var toolbarY = selection.maxY + 10
        if toolbarY + toolbarHeight > bounds.maxY - 8 {
            toolbarY = selection.minY - toolbarHeight - 10
        }
        inlineToolbar.frame = CGRect(x: min(max(selection.midX - toolbarWidth / 2, 8),
                                             bounds.maxX - toolbarWidth - 8),
                                     y: max(8, toolbarY), width: toolbarWidth,
                                     height: toolbarHeight)
    }

    func refreshPointerState() {
        guard let panel else { return }
        let point = CGPoint(x: NSEvent.mouseLocation.x - panel.screenFrame.minX,
                            y: panel.screenFrame.maxY - NSEvent.mouseLocation.y)
        if bounds.contains(point) {
            hoverPoint = point
            hoveredWindow = controller?.acceptsWindowClick == true
                ? ScreenshotSupport.window(at: hoverPoint, in: windows)
                : nil
        }
        needsDisplay = true
    }

    func updateLoupeImage(_ image: CGImage?) {
        loupeImage = image
        inlinePixelatedImage = nil
        needsDisplay = true
    }

    func refreshCaptureGuide() {
        guideHost.rootView = CaptureGuideView(
            strings: strings,
            purpose: purpose,
            offersScrollingCapture: controller?.offersScrollingCapture ?? false,
            requiresDraggedRegion: controller?.requiresDraggedRegion ?? false,
            scrollingCaptureEnabled: controller?.scrollingCaptureEnabled ?? false,
            screenCaptureOptions: screenCaptureOptions,
            toggleScrollingCapture: { [weak controller] in
                controller?.toggleScrollingCapture()
            })
    }

    func captureToolDidChange() {
        dragOrigin = nil
        selection = .zero
        hoveredWindow = nil
        refreshGuideVisibility()
        refreshCaptureGuide()
        needsLayout = true
        needsDisplay = true
        refreshPointerState()
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        if inlineEditing, editorState.isPendingNoteAnchor {
            editorState.previewPendingNote(to: hoverPoint)
            needsDisplay = true
        }
        hoveredWindow = controller?.acceptsWindowClick == true
            ? ScreenshotSupport.window(at: hoverPoint, in: windows)
            : nil
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        refreshGuideVisibility()
    }

    // System chrome can take pointer ownership without the pointer leaving
    // this display. Re-evaluate the real location so the chooser does not
    // disappear over the Dock, menu bar or its own interactive controls.
    override func mouseExited(with event: NSEvent) {
        refreshGuideVisibility()
    }

    override func scrollWheel(with event: NSEvent) {
        guard acceptsPointerInput, let controller, controller.loupeEnabled else {
            super.scrollWheel(with: event)
            return
        }
        controller.adjustLoupeZoom(by: event.scrollingDeltaY)
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsPointerInput else { return }
        let point = convert(event.locationInWindow, from: nil)
        if inlineEditing {
            if inlineTextEditor != nil { commitInlineText() }
            if editorState.isPendingNoteAnchor {
                editorState.commitPendingNote(at: point)
                needsDisplay = true
                return
            }
            if event.clickCount >= 2,
               let mark = editorState.editableSpecialMark(at: point) {
                beginInlineTextEditing(mark)
                return
            }
            if let handle = ScreenshotSupport.handle(at: point, rect: selection, tolerance: 9) {
                resizeHandle = handle
                resizeOrigin = selection
            } else if editorState.beginAdjustment(at: point) {
                needsDisplay = true
            } else if editorState.hasActiveTool, selection.contains(point) {
                editorState.begin(at: point)
                needsDisplay = true
            } else if selection.contains(point) {
                moveOrigin = selection
                lastDragPoint = point
            }
            return
        }
        hoverPoint = point
        dragOrigin = point
        controller?.selectionInProgress = true
        lastDragPoint = point
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsPointerInput else { return }
        let point = convert(event.locationInWindow, from: nil)
        if inlineEditing {
            if editorState.isDrawing || editorState.isAdjusting {
                editorState.drag(to: point)
            } else if let handle = resizeHandle, let origin = resizeOrigin {
                selection = ScreenshotSupport.clamp(
                    ScreenshotSupport.resizedRect(origin, dragging: handle, to: point), to: bounds)
            } else if let origin = moveOrigin {
                let delta = CGPoint(x: point.x - lastDragPoint.x, y: point.y - lastDragPoint.y)
                selection = ScreenshotSupport.movedRect(origin, by: delta, within: bounds)
            }
            needsLayout = true
            needsDisplay = true
            return
        }
        guard let controller, let origin = dragOrigin else { return }
        hoverPoint = point
        if controller.isPickingColor {
            lastDragPoint = point
            needsDisplay = true
            return
        }
        if controller.spaceIsDown, selection.width > 0 {
            // Space pans the selection instead of resizing it.
            let delta = CGPoint(x: point.x - lastDragPoint.x, y: point.y - lastDragPoint.y)
            selection.origin.x += delta.x
            selection.origin.y += delta.y
            dragOrigin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        } else {
            selection = ScreenshotSupport.selectionRect(
                from: origin,
                to: point,
                square: event.modifierFlags.contains(.shift),
                fromCenter: event.modifierFlags.contains(.option))
        }
        selection = ScreenshotSupport.clamp(selection, to: bounds)
        lastDragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsPointerInput, let controller, let panel else { return }
        let point = convert(event.locationInWindow, from: nil)
        if inlineEditing {
            if editorState.isDrawing || editorState.isAdjusting {
                let completed = editorState.end(at: point)
                if completed?.kind == .note || completed?.kind == .text {
                    beginInlineTextEditing(completed!, selectAll: true)
                }
            }
            resizeHandle = nil
            resizeOrigin = nil
            moveOrigin = nil
            needsDisplay = true
            return
        }
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        controller.spaceIsDown = false

        if controller.isPickingColor {
            selection = .zero
            controller.confirmColor(at: point, on: panel)
            return
        }

        let clicked = ScreenshotSupport.isClick(from: origin, to: point)
        if clicked {
            if controller.acceptsWindowClick,
               let target = ScreenshotSupport.window(at: point, in: windows) {
                controller.confirmWindow(target.windowID, frame: target.frame, on: panel)
            }
            selection = .zero
            needsDisplay = true
            controller.selectionInProgress = false
            return
        }
        guard selection.width >= 2, selection.height >= 2 else {
            selection = .zero
            controller.selectionInProgress = false
            needsDisplay = true
            return
        }
        guard controller.offersInlineScreenshotEditing else {
            controller.confirmRegion(selection, on: panel)
            return
        }
        inlineEditing = true
        controller.beginInlineEditing(on: panel)
        if frozenImage == nil { controller.ensureInlineSourceImages() }
        controller.selectionInProgress = false
        inlineToolbar.isHidden = false
        needsLayout = true
        needsDisplay = true
    }

    private func confirmInlineSelection(
        delivery: ScreenshotSelectionController.Capture.Delivery
    ) {
        commitInlineText()
        guard inlineEditing, let controller, let panel,
              selection.width >= 2, selection.height >= 2 else { return }
        inlineToolbar.isHidden = true
        controller.confirmRegion(selection, payload: editorState.payload,
                                 delivery: delivery, on: panel)
    }

    private func beginInlineScrollingCapture() {
        commitInlineText()
        guard inlineEditing, let controller, let panel,
              controller.offersScrollingCapture,
              selection.width >= 2, selection.height >= 2 else { return }
        controller.scrollingCaptureEnabled = true
        inlineToolbar.isHidden = true
        controller.confirmRegion(selection, on: panel)
    }

    private func beginInlineTextEditing(_ mark: InlineSpecialMark, selectAll: Bool = false) {
        commitInlineText()
        // Reopening an existing label must use that label's own appearance,
        // not whichever tool happened to be used immediately beforehand.
        editorState.color = mark.color
        editorState.stroke = mark.stroke
        editorState.lineStyle = mark.lineStyle
        editorState.fontDesign = mark.fontDesign
        editorState.bold = mark.bold
        editorState.fontSize = Double(mark.fontSize)
        let point = mark.kind == .note ? mark.end : mark.start
        beginInlineTextEditor(text: mark.text,
                              frame: mark.kind == .text ? inlineTextRect(mark)
                                  : (mark.kind == .note ? inlineNoteRect(mark)
                                     : editorFrame(at: point, kind: mark.kind)),
                              point: mark.start,
                              kind: mark.kind,
                              markID: mark.id,
                              selectAll: selectAll)
    }

    private func editorFrame(at point: CGPoint, kind: InlineSpecialTool) -> CGRect {
        let width = min(kind == .note ? 220 : 300,
                        max(150, selection.maxX - point.x))
        let height: CGFloat = kind == .note ? 92 : 110
        var origin = kind == .note
            ? CGPoint(x: point.x - 4, y: point.y - 18)
            : point
        origin.x = min(max(origin.x, selection.minX + 4), selection.maxX - width - 4)
        origin.y = min(max(origin.y, selection.minY + 4), selection.maxY - height - 4)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func beginInlineTextEditor(text: String,
                                       frame: CGRect,
                                       point: CGPoint,
                                       kind: InlineSpecialTool,
                                       markID: UUID?,
                                       selectAll: Bool = false) {
        let scroll = InlineTextEditorScrollView(frame: frame)
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        scroll.drawsBackground = true
        scroll.backgroundColor = kind == .note
            ? (ScreenshotRenderer.nsColor(editorState.color)
                .blended(withFraction: 0.72, of: .white) ?? .white)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.96)
        scroll.hasVerticalScroller = kind != .note
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        let editorFontSize = CGFloat(editorState.fontSize)
        textView.font = inlineCaptureFont(design: editorState.fontDesign,
                                          bold: editorState.bold,
                                          size: editorFontSize)
        textView.textColor = kind == .note ? NSColor.labelColor
            : ScreenshotRenderer.nsColor(editorState.color)
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.string = text
        scroll.documentView = textView
        addSubview(scroll)
        inlineTextEditor = scroll
        inlineTextView = textView
        inlineTextPoint = point
        inlineTextKind = kind
        inlineTextMarkID = markID
        scroll.onWidthChange = { [weak self] width in
            guard let self else { return }
            if let markID { self.editorState.updateSpecialWidth(id: markID, width: width) }
            self.resizeInlineTextEditor()
        }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(selectAll
            ? NSRange(location: 0, length: textView.string.utf16.count)
            : NSRange(location: textView.string.utf16.count, length: 0))
        resizeInlineTextEditor()
    }

    func textDidChange(_ notification: Notification) {
        resizeInlineTextEditor()
    }

    private func resizeInlineTextEditor() {
        guard let editor = inlineTextEditor, let textView = inlineTextView,
              let container = textView.textContainer,
              let layout = textView.layoutManager else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        var frame = editor.frame
        frame.size.height = min(max(40, ceil(used) + 18), max(40, selection.maxY - frame.minY - 4))
        editor.frame = frame
    }

    private func commitInlineText() {
        guard let editor = inlineTextEditor, let textView = inlineTextView,
              let point = inlineTextPoint else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = inlineTextMarkID {
            if !text.isEmpty { editorState.updateSpecialText(id: id, text: text) }
        } else if !text.isEmpty {
            editorState.addText(text, at: point, width: editor.frame.width)
        }
        editor.removeFromSuperview()
        inlineTextEditor = nil
        inlineTextView = nil
        inlineTextPoint = nil
        inlineTextMarkID = nil
        inlineTextKind = .text
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    fileprivate func deleteSelectedEditorItem() {
        guard inlineTextEditor == nil else { return }
        if editorState.deleteSelection() { needsDisplay = true }
    }

    func refreshGuideVisibility() {
        guard let panel else {
            guideHost.isHidden = true
            return
        }
        guideHost.isHidden = inlineEditing || !ScreenshotSupport.captureGuideIsVisible(
            pointerOnDisplay: panel.screenFrame.contains(NSEvent.mouseLocation),
            selectionInProgress: controller?.selectionInProgress ?? true,
            capturePending: isCapturePending)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let controller,
              let panel
        else { return }
        let mouseIsOnThisScreen = panel.screenFrame.contains(NSEvent.mouseLocation)

        // Use the same neutral veil before selection and during editing,
        // regardless of whether the underlying screen is live or frozen.
        context.setFillColor(CGColor(gray: 0.38, alpha: 0.18))
        if selection.width > 0, selection.height > 0 {
            context.beginPath()
            context.addRect(bounds)
            context.addPath(CGPath(roundedRect: selection,
                                   cornerWidth: 8,
                                   cornerHeight: 8,
                                   transform: nil))
            context.fillPath(using: .evenOdd)
            drawSelectionChrome(context, pixelScale: panel.pixelScale)
            if inlineEditing {
                drawInlineAnnotations(context)
                drawInlineSpecialMarks(context)
                drawSelectedAnnotationHandles(context)
                drawSelectedSpecialHandles(context)
                drawInlineSelectionHandles(context)
            }
        } else if dragOrigin == nil, hoveredWindow != nil {
            if let hovered = hoveredWindow {
                // A hover is only a candidate, not a confirmed selection.
                // Keep it dimmed until the user clicks or drags a selection.
                context.fill(bounds)
                drawWindowHighlight(context, rect: hovered.frame)
            } else {
                context.fill(bounds)
            }
        } else {
            context.fill(bounds)
        }

        if mouseIsOnThisScreen, !isCapturePending, !controller.spaceIsDown, !inlineEditing {
            let point = isDragging ? lastDragPoint : hoverPoint
            drawCoordinateGuides(context, at: point, pixelScale: panel.pixelScale)
        }

        if controller.loupeEnabled, !controller.spaceIsDown, !inlineEditing,
           mouseIsOnThisScreen, let loupeImage {
            let point = isDragging ? lastDragPoint : hoverPoint
            drawCaptureLoupe(context,
                             image: loupeImage,
                             near: point,
                             zoom: controller.loupeZoom)
        }

        if let ghostRect, dragOrigin == nil, selection == .zero {
            drawGhost(context, rect: ghostRect)
        }
    }

    private func drawCoordinateGuides(_ context: CGContext,
                                      at point: CGPoint,
                                      pixelScale: CGFloat) {
        context.saveGState()
        context.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.55, blue: 1, alpha: 0.82))
        context.setLineWidth(1)
        context.beginPath()
        context.move(to: CGPoint(x: bounds.minX, y: point.y))
        context.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        context.move(to: CGPoint(x: point.x, y: bounds.minY))
        context.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        context.strokePath()
        context.restoreGState()

        let pixelX = Int((point.x * pixelScale).rounded())
        let pixelY = Int((point.y * pixelScale).rounded())
        drawBadge("x: \(pixelX)   y: \(pixelY)",
                  near: CGPoint(x: point.x, y: point.y + 14))
    }

    private func drawSelectionChrome(_ context: CGContext, pixelScale: CGFloat) {
        let outer = CGPath(roundedRect: selection.insetBy(dx: -1.5, dy: -1.5),
                           cornerWidth: 9,
                           cornerHeight: 9,
                           transform: nil)
        let inner = CGPath(roundedRect: selection.insetBy(dx: -0.5, dy: -0.5),
                           cornerWidth: 8,
                           cornerHeight: 8,
                           transform: nil)
        context.saveGState()
        context.setShadow(offset: .zero,
                          blur: 9,
                          color: CGColor(srgbRed: 0.18, green: 0.55, blue: 1, alpha: 0.55))
        context.addPath(outer)
        context.setStrokeColor(CGColor(srgbRed: 0.18, green: 0.55, blue: 1, alpha: 0.98))
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()
        context.addPath(inner)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(1)
        context.strokePath()

        let pixelWidth = Int((selection.width * pixelScale).rounded())
        let pixelHeight = Int((selection.height * pixelScale).rounded())
        drawBadge("\(pixelWidth) × \(pixelHeight)",
                  near: CGPoint(x: selection.midX, y: selection.maxY + 10))
    }

    private func drawInlineSelectionHandles(_ context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(srgbRed: 0.16, green: 0.48, blue: 0.98, alpha: 1))
        context.setLineWidth(2)
        for handle in ScreenshotSupport.Handle.allCases {
            let point = handle.position(in: selection)
            let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
        context.restoreGState()
    }

    private func drawSelectedAnnotationHandles(_ context: CGContext) {
        guard let id = editorState.selectedAnnotationID,
              let mark = editorState.annotations.first(where: { $0.id == id }) else { return }
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.48, blue: 1, alpha: 1))
        context.setLineWidth(1.5)
        let positions: [CGPoint]
        if mark.points.count >= 2 { positions = [mark.points[0], mark.points[1]] }
        else { positions = ScreenshotSupport.Handle.allCases.map { $0.position(in: mark.rect) } }
        for point in positions {
            let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fillEllipse(in: rect); context.strokeEllipse(in: rect)
        }
        context.restoreGState()
    }

    private func drawSelectedSpecialHandles(_ context: CGContext) {
        guard let id = editorState.selectedSpecialID,
              let mark = editorState.specialMarks.first(where: { $0.id == id }) else { return }
        let positions: [CGPoint]
        switch mark.kind {
        case .magnifier:
            let radius = max(68, hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y))
            let rect = CGRect(x: mark.start.x - radius, y: mark.start.y - radius,
                              width: radius * 2, height: radius * 2)
            positions = ScreenshotSupport.Handle.allCases.map { $0.position(in: rect) }
        case .note:
            let rect = inlineNoteRect(mark)
            positions = [mark.start, mark.end, CGPoint(x: rect.maxX, y: rect.midY)]
        case .text:
            let rect = inlineTextRect(mark)
            positions = [CGPoint(x: rect.minX, y: rect.midY),
                         CGPoint(x: rect.maxX, y: rect.midY)]
        case .watermark: positions = []
        }
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.48, blue: 1, alpha: 1))
        context.setLineWidth(1.5)
        for point in positions {
            let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fillEllipse(in: rect); context.strokeEllipse(in: rect)
        }
        context.restoreGState()
    }

    private func drawInlineAnnotations(_ context: CGContext) {
        let ordinary = editorState.annotations.filter { $0.tool != .pixelate }
        ScreenshotRenderer.drawAnnotations(ordinary,
                                           in: context,
                                           pixelated: nil,
                                           imageSize: bounds.size,
                                           scale: 1,
                                           annotationShadowsEnabled: false)
        context.saveGState()
        for mark in editorState.annotations where mark.tool == .pixelate {
            drawInlinePixelate(mark, context: context)
        }
        context.restoreGState()
    }

    private func drawInlinePixelate(_ mark: ScreenshotSupport.Annotation,
                                    context: CGContext) {
        if inlinePixelatedImage == nil, let source = frozenImage ?? loupeImage {
            inlinePixelatedImage = ScreenshotRenderer.pixelatedImage(from: source)
        }
        guard let pixelated = inlinePixelatedImage else {
            context.setFillColor(CGColor(gray: 0.25, alpha: 0.32))
            if mark.points.count > 1 {
                context.setStrokeColor(CGColor(gray: 0.25, alpha: 0.42))
                context.setLineWidth(max(14, mark.stroke.width * 5))
                context.setLineCap(.round); context.setLineJoin(.round)
                context.beginPath(); context.move(to: mark.points[0])
                for point in mark.points.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            } else { context.fill(mark.rect) }
            return
        }
        context.saveGState()
        if mark.points.count > 1 {
            context.beginPath(); context.move(to: mark.points[0])
            for point in mark.points.dropFirst() { context.addLine(to: point) }
            context.setLineWidth(max(14, mark.stroke.width * 5))
            context.setLineCap(.round); context.setLineJoin(.round)
            context.replacePathWithStrokedPath(); context.clip()
        } else { context.clip(to: mark.rect) }
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(pixelated, in: bounds)
        context.restoreGState()
    }

    private func drawInlineSpecialMarks(_ context: CGContext) {
        for mark in editorState.specialMarks {
            switch mark.kind {
            case .text:
                let rect = inlineTextRect(mark)
                context.saveGState()
                context.setStrokeColor(ScreenshotRenderer.color(mark.color, alpha: 0.92))
                context.setLineWidth(max(1, mark.stroke.width * 0.55))
                context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                       cornerWidth: 7, cornerHeight: 7, transform: nil))
                context.strokePath()
                context.restoreGState()
                drawInlineText(mark.text, in: rect, color: mark.color,
                               fontSize: mark.fontSize,
                               design: mark.fontDesign, bold: mark.bold)
            case .note:
                drawInlineNote(mark, context: context)
            case .magnifier:
                drawInlineMagnifier(mark, context: context)
            case .watermark:
                break
            }
        }
        if editorState.watermarkEnabled, !editorState.inputText.isEmpty {
            drawInlineWatermark(editorState.inputText, context: context)
        }
    }

    private func drawInlineText(_ text: String, in rect: CGRect,
                                color: ScreenshotSupport.ColorID,
                                fontSize: CGFloat,
                                design: InlineFontDesign,
                                bold: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: inlineCaptureFont(design: design, bold: bold,
                                     size: fontSize),
            .foregroundColor: ScreenshotRenderer.nsColor(color),
        ]
        text.draw(in: rect.insetBy(dx: 8, dy: 6), withAttributes: attributes)
    }

    private func drawInlineNote(_ mark: InlineSpecialMark, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(ScreenshotRenderer.color(mark.color))
        context.setLineWidth(mark.stroke.width)
        context.setLineDash(phase: 0, lengths: mark.lineStyle.inlineDashPattern)
        context.move(to: mark.start)
        context.addLine(to: mark.end)
        context.strokePath()
        let box = inlineNoteRect(mark)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 8,
                          color: CGColor(gray: 0, alpha: 0.22))
        let noteFill = ScreenshotRenderer.nsColor(mark.color)
            .blended(withFraction: 0.72, of: .white) ?? .white
        context.setFillColor(noteFill.cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8,
                               transform: nil))
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(ScreenshotRenderer.color(mark.color, alpha: 0.82))
        context.setLineWidth(max(1, mark.stroke.width * 0.65))
        context.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8,
                               transform: nil))
        context.strokePath()
        context.setFillColor(ScreenshotRenderer.color(mark.color))
        context.fillEllipse(in: CGRect(x: box.minX + 8, y: box.midY - 3,
                                       width: 6, height: 6))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: inlineCaptureFont(design: mark.fontDesign, bold: mark.bold,
                                     size: mark.fontSize),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        ]
        mark.text.draw(in: CGRect(x: box.minX + 21, y: box.minY + 9,
                                  width: box.width - 29, height: box.height - 15),
                       withAttributes: attributes)
        context.restoreGState()
    }

    private func drawInlineMagnifier(_ mark: InlineSpecialMark, context: CGContext) {
        let radius = max(68, hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y))
        let frame = CGRect(x: mark.start.x - radius, y: mark.start.y - radius,
                           width: radius * 2, height: radius * 2)
        let path = mark.magnifierShape == .circle
            ? CGPath(ellipseIn: frame, transform: nil)
            : CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let image = frozenImage {
            let sourcePoint = ScreenshotSupport.imagePixelPoint(fromView: mark.start,
                                                                viewSize: bounds.size,
                                                                imageSize: CGSize(width: image.width,
                                                                                  height: image.height))
        let source = ScreenshotSupport.cropLoupeSampleRect(around: sourcePoint,
                                                               imageSize: CGSize(width: image.width,
                                                                                 height: image.height),
                                                               sideLength: radius * 2
                                                                   / max(mark.magnifierZoom, 1))
            if let sample = image.cropping(to: source) {
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(sample, in: CGRect(x: frame.minX,
                                                y: bounds.height - frame.maxY,
                                                width: frame.width, height: frame.height))
            }
        }
        context.restoreGState()
        context.setStrokeColor(ScreenshotRenderer.color(mark.color))
        context.setLineWidth(mark.stroke.width)
        context.addPath(path)
        context.strokePath()
        // Editing needs a precise source anchor, but the capture-stage loupe
        // deliberately stays cross-free and visually quiet.
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fillEllipse(in: CGRect(x: mark.start.x - 4, y: mark.start.y - 4,
                                       width: 8, height: 8))
        context.setFillColor(ScreenshotRenderer.color(mark.color))
        context.fillEllipse(in: CGRect(x: mark.start.x - 2, y: mark.start.y - 2,
                                       width: 4, height: 4))
    }

    private func drawInlineWatermark(_ text: String, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: inlineCaptureFont(design: editorState.fontDesign,
                                     bold: editorState.bold,
                                     size: 18 * CGFloat(editorState.watermarkScale)),
            .foregroundColor: ScreenshotRenderer.nsColor(editorState.color)
                .withAlphaComponent(editorState.watermarkOpacity),
        ]
        context.saveGState()
        context.clip(to: selection)
        for y in stride(from: selection.minY, through: selection.maxY,
                        by: 76 * CGFloat(editorState.watermarkSpacing)) {
            for x in stride(from: selection.minX - 40, through: selection.maxX,
                            by: 190 * CGFloat(editorState.watermarkSpacing)) {
                context.saveGState()
                context.translateBy(x: x, y: y)
                context.rotate(by: CGFloat(editorState.watermarkAngle) * .pi / 180)
                text.draw(at: .zero, withAttributes: attributes)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    private func drawWindowHighlight(_ context: CGContext, rect: CGRect) {
        let path = CGPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25),
                          cornerWidth: 9,
                          cornerHeight: 9,
                          transform: nil)
        // Only outline the candidate; retain the neutral veil inside it.
        context.addPath(path)
        context.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.62, blue: 1, alpha: 0.95))
        context.setLineWidth(2.5)
        context.strokePath()
    }

    private func drawGhost(_ context: CGContext, rect: CGRect) {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.65))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.stroke(rect)
        context.restoreGState()
    }

    // MARK: Pixel loupe

    private func drawCaptureLoupe(_ context: CGContext,
                                  image: CGImage,
                                  near point: CGPoint,
                                  zoom: CGFloat) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let pixelPoint = ScreenshotSupport.imagePixelPoint(
            fromView: point,
            viewSize: bounds.size,
            imageSize: imageSize)
        let source = ScreenshotSupport.cropLoupeSampleRect(
            around: pixelPoint,
            imageSize: imageSize,
            sideLength: ScreenshotSupport.captureLoupeSampleSide(zoom: zoom))
        guard let sample = image.cropping(to: source) else { return }

        let frame = captureLoupeFrame(near: point, size: 70)
        let path = CGPath(roundedRect: frame,
                          cornerWidth: 9,
                          cornerHeight: 9,
                          transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .none
        // CGImage draws bottom-up inside the flipped overlay, so mirror only
        // this destination to keep the magnified pixels upright.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let flippedFrame = CGRect(x: frame.minX,
                                  y: bounds.height - frame.maxY,
                                  width: frame.width,
                                  height: frame.height)
        context.draw(sample, in: flippedFrame)
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(1.5)
        context.strokePath()
        context.restoreGState()
    }

    private func captureLoupeFrame(near point: CGPoint, size: CGFloat) -> CGRect {
        let gap: CGFloat = 16
        let inset: CGFloat = 8
        var origin = CGPoint(x: point.x + gap,
                             y: point.y - size - gap)
        if origin.x + size > bounds.maxX - inset {
            origin.x = point.x - size - gap
        }
        if origin.y < bounds.minY + inset {
            origin.y = point.y + gap
        }
        origin.x = min(max(origin.x, bounds.minX + inset), bounds.maxX - size - inset)
        origin.y = min(max(origin.y, bounds.minY + inset), bounds.maxY - size - inset)
        return CGRect(origin: origin, size: CGSize(width: size, height: size))
    }

    // MARK: Text chrome

    private func drawBadge(_ text: String, near point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var rect = CGRect(x: point.x - size.width / 2 - 7,
                          y: point.y - 3,
                          width: size.width + 14,
                          height: size.height + 6)
        rect.origin.x = max(6, min(rect.origin.x, bounds.maxX - rect.width - 6))
        rect.origin.y = max(6, min(rect.origin.y, bounds.maxY - rect.height - 6))
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(white: 0, alpha: 0.72).setFill()
        path.fill()
        text.draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 3), withAttributes: attributes)
    }

}

private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var passesThrough = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThrough ? nil : super.hitTest(point)
    }
}

private final class InlineTextEditorScrollView: NSScrollView {
    var onWidthChange: ((CGFloat) -> Void)?
    private var resizingWidth = false

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(CGRect(x: bounds.maxX - 10, y: 0, width: 10, height: bounds.height),
                      cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= bounds.maxX - 10 else { super.mouseDown(with: event); return }
        resizingWidth = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard resizingWidth, let superview else { super.mouseDragged(with: event); return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let width = max(120, point.x - frame.minX)
        frame.size.width = width
        onWidthChange?(width)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if resizingWidth { resizingWidth = false; return }
        super.mouseUp(with: event)
    }
}

private struct CaptureGuideView: View {
    let strings: ScreenshotFeatureStrings
    let purpose: String?
    let offersScrollingCapture: Bool
    let requiresDraggedRegion: Bool
    let scrollingCaptureEnabled: Bool
    let screenCaptureOptions: ScreenCaptureSelectionOptions?
    let toggleScrollingCapture: () -> Void

    var body: some View {
        if let screenCaptureOptions {
            UnifiedCaptureGuideContent(strings: strings,
                                       options: screenCaptureOptions,
                                       offersScrollingCapture: offersScrollingCapture,
                                       scrollingCaptureEnabled: scrollingCaptureEnabled,
                                       toggleScrollingCapture: toggleScrollingCapture)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
        } else {
            standardGuide
        }
    }

    private var standardGuide: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                if !requiresDraggedRegion && !scrollingCaptureEnabled {
                    CaptureKeyHint(key: "↩", icon: "rectangle.inset.filled")
                }
                if offersScrollingCapture {
                    CaptureKeyHint(key: scrollingCaptureEnabled ? "S on" : "S",
                                   icon: "arrow.up.and.down.square")
                }
                CaptureKeyHint(key: "Z", icon: "plus.magnifyingglass")
                CaptureKeyHint(key: "esc", icon: "xmark")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 7)
        .allowsHitTesting(false)
    }

    private var title: String {
        guard let purpose, !purpose.isEmpty else { return strings.hintDrag }
        return purpose
    }

    private var subtitle: String {
        let base = requiresDraggedRegion || scrollingCaptureEnabled
            ? strings.scrollingCaptureSelectionHint
            : purpose?.isEmpty == false
            ? strings.hintDrag + "  ·  " + strings.hintClick
            : strings.hintClick
        guard offersScrollingCapture else { return base }
        let scrolling = scrollingCaptureEnabled
            ? strings.scrollingCaptureHintOn
            : strings.scrollingCaptureHintOff
        return base + "  ·  " + scrolling
    }

}

private struct UnifiedCaptureGuideContent: View {
    let strings: ScreenshotFeatureStrings
    @ObservedObject var options: ScreenCaptureSelectionOptions
    @ObservedObject private var l10n = L10n.shared
    let offersScrollingCapture: Bool
    let scrollingCaptureEnabled: Bool
    let toggleScrollingCapture: () -> Void
    @State private var hoveredTool: ScreenCaptureTool?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                captureModePalette
                escapeHint
            }
            contextualGuide
            RecorderSelectionAudioControls(options: options.recorderAudio)
                .opacity(options.selectedTool == .recording ? 1 : 0)
                .allowsHitTesting(options.selectedTool == .recording)
                .accessibilityHidden(options.selectedTool != .recording)
        }
    }

    private var contextualGuide: some View {
        HStack(spacing: 7) {
            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            CaptureKeyHint(key: "1–4", icon: "keyboard")
            if options.selectedTool != .color {
                CaptureKeyHint(key: "↩", icon: "rectangle.inset.filled")
                if offersScrollingCapture, options.selectedTool == .screenshot {
                    Button(action: toggleScrollingCapture) {
                        CaptureKeyHint(key: scrollingCaptureEnabled ? "滚动截图 · 已选择" : "滚动截图",
                                       icon: "arrow.up.and.down.square")
                    }
                    .buttonStyle(.plain)
                    .help(strings.scrollingCaptureHintOff)
                }
                CaptureKeyHint(key: "Z", icon: "plus.magnifyingglass")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var escapeHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
            Text("esc")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    private var captureModePalette: some View {
        HStack(spacing: 2) {
            ForEach(options.availableTools, id: \.self) { tool in
                captureModeButton(tool)
            }
        }
        .padding(4)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    private func captureModeButton(_ tool: ScreenCaptureTool) -> some View {
        let selected = options.selectedTool == tool
        let hovered = hoveredTool == tool
        let title = tool.settingsTitle(l10n.s, language: l10n.language)
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                options.select(tool)
            }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.shortcutKey)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(width: 19, height: 19)
                        .background(selected ? Color.accentColor : Color.primary.opacity(0.11),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Image(systemName: tool.systemImageName)
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.78))
            .frame(width: 116, height: 48)
            .background(selected ? Color.accentColor.opacity(0.16)
                        : Color.primary.opacity(hovered ? 0.08 : 0.035),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.48 : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredTool = hovering ? tool : nil
            }
        }
        .help("\(title) (\(tool.shortcutKey))")
        .accessibilityLabel(title)
        .accessibilityValue(tool.shortcutKey)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var subtitle: String {
        switch options.selectedTool {
        case .screenshot:
            let base = strings.hintDrag + "  ·  " + strings.hintClick
            guard offersScrollingCapture else { return base }
            return base + "  ·  "
                + (scrollingCaptureEnabled
                   ? strings.scrollingCaptureHintOn
                   : strings.scrollingCaptureHintOff)
        case .recording:
            return FeatureStrings.recorder(l10n.language).selectionPurpose
                + "  ·  " + strings.hintDrag + "  ·  " + strings.hintClick
        case .text:
            return l10n.s.ocrCaption
        case .color:
            return l10n.s.colorPickerCaption
        }
    }
}

private struct CaptureKeyHint: View {
    let key: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            if icon == "arrow.up.and.down.square" {
                ScrollCaptureIcon().scaleEffect(0.7).frame(width: 14, height: 14)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct RecorderSelectionAudioControls: View {
    @ObservedObject var options: RecorderSelectionAudioOptions
    @ObservedObject private var l10n = L10n.shared

    private var strings: RecorderFeatureStrings { FeatureStrings.recorder(l10n.language) }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $options.systemAudio) {
                Label(strings.systemAudioTrackLabel, systemImage: "speaker.wave.2.fill")
            }
            Toggle(isOn: $options.microphone) {
                Label(strings.microphoneTrackLabel, systemImage: "mic.fill")
            }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(4)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

private final class InlineCaptureEditorState: ObservableObject {
    @Published var tool: ScreenshotSupport.Tool?
    @Published var specialTool: InlineSpecialTool?
    @Published var color: ScreenshotSupport.ColorID = .green {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(color.rawValue, forKey: InlineCapturePreferenceKey.color)
            applyColorToSelection()
        }
    }
    @Published var stroke: ScreenshotSupport.StrokeID = .medium {
        didSet {
            UserDefaults.standard.set(stroke.rawValue, forKey: InlineCapturePreferenceKey.stroke)
            applyStrokeToSelection()
        }
    }
    @Published var lineStyle: ScreenshotSupport.LineStyle = .solid {
        didSet {
            UserDefaults.standard.set(lineStyle.rawValue, forKey: InlineCapturePreferenceKey.lineStyle)
            mutateSelectedAnnotation { $0.lineStyle = lineStyle }
            mutateSelectedSpecial { if $0.kind == .note { $0.lineStyle = lineStyle } }
        }
    }
    @Published var filled = false {
        didSet {
            UserDefaults.standard.set(filled, forKey: InlineCapturePreferenceKey.filled)
            mutateSelectedAnnotation { $0.filled = filled }
        }
    }
    @Published var arrowStyle: ScreenshotSupport.ArrowStyle = .filled {
        didSet {
            UserDefaults.standard.set(arrowStyle.rawValue, forKey: InlineCapturePreferenceKey.arrowStyle)
            mutateSelectedAnnotation { $0.arrowStyle = arrowStyle }
        }
    }
    @Published var mosaicMode: ScreenshotSupport.MosaicMode = .rectangle {
        didSet { UserDefaults.standard.set(mosaicMode.rawValue, forKey: InlineCapturePreferenceKey.mosaicMode) }
    }
    @Published var magnifierShape: ScreenshotSupport.MagnifierShape = .circle {
        didSet {
            UserDefaults.standard.set(magnifierShape.rawValue, forKey: InlineCapturePreferenceKey.magnifierShape)
            mutateSelectedSpecial { $0.magnifierShape = magnifierShape }
        }
    }
    @Published var magnifierZoom = 1.6 {
        didSet {
            UserDefaults.standard.set(magnifierZoom, forKey: InlineCapturePreferenceKey.magnifierZoom)
            mutateSelectedSpecial { $0.magnifierZoom = CGFloat(magnifierZoom) }
        }
    }
    @Published var fontDesign: InlineFontDesign = .system {
        didSet {
            UserDefaults.standard.set(fontDesign.rawValue, forKey: InlineCapturePreferenceKey.fontDesign)
            mutateSelectedSpecial { $0.fontDesign = fontDesign }
        }
    }
    @Published var bold = true {
        didSet {
            UserDefaults.standard.set(bold, forKey: InlineCapturePreferenceKey.bold)
            mutateSelectedSpecial { $0.bold = bold }
        }
    }
    @Published var fontSize = 18.0 {
        didSet {
            let clamped = min(72, max(10, fontSize))
            if clamped != fontSize { fontSize = clamped; return }
            UserDefaults.standard.set(fontSize, forKey: InlineCapturePreferenceKey.fontSize)
            mutateSelectedSpecial {
                if $0.kind == .text || $0.kind == .note { $0.fontSize = CGFloat(fontSize) }
            }
        }
    }
    @Published var annotations: [ScreenshotSupport.Annotation] = []
    @Published var selectedAnnotationID: UUID? {
        didSet { if selectedAnnotationID != nil { synchronizeFromSelectedAnnotation() } }
    }
    @Published var specialMarks: [InlineSpecialMark] = []
    @Published var selectedSpecialID: UUID? {
        didSet { if selectedSpecialID != nil { synchronizeFromSelectedSpecial() } }
    }
    @Published var inputText = "" {
        didSet {
            guard !isSynchronizingSelection else { return }
            mutateSelectedSpecial {
                if $0.kind == .text || $0.kind == .note { $0.text = inputText }
            }
        }
    }
    @Published var watermarkOpacity = 0.28
    @Published var watermarkAngle = -22.0
    @Published var watermarkScale = 1.0
    @Published var watermarkSpacing = 1.0
    @Published var watermarkEnabled = false
    private var start: CGPoint = .zero
    private var draftID: UUID?
    private var specialDraftID: UUID?
    private var pendingNotePlacement = false
    private var adjustingAnnotationID: UUID?
    private var adjustmentHandle: ScreenshotSupport.Handle?
    private var adjustmentStart = CGPoint.zero
    private var adjustmentRect = CGRect.zero
    private var adjustmentPoints: [CGPoint] = []
    private var adjustmentRecorded = false
    private var adjustingSpecialID: UUID?
    private var specialAdjustmentStart = CGPoint.zero
    private var specialAdjustmentOriginal: InlineSpecialMark?
    private var specialAdjustmentEndpoint: Int?
    private var specialAdjustmentHandle: ScreenshotSupport.Handle?
    private var specialNoteWidthAdjustment = false
    private enum HistoryItem {
        case annotation(UUID), special(UUID)
        case mutation(ScreenshotSupport.Annotation)
        case specialMutation(InlineSpecialMark)
        case deletedAnnotation(ScreenshotSupport.Annotation)
        case deletedSpecial(InlineSpecialMark)
        case watermark(Bool)
    }
    private var history: [HistoryItem] = []
    var isDrawing: Bool { draftID != nil || specialDraftID != nil }
    var isPendingNoteAnchor: Bool { pendingNotePlacement && specialDraftID != nil }
    var isAdjusting: Bool { adjustingAnnotationID != nil || adjustingSpecialID != nil }
    var hasActiveTool: Bool { tool != nil || specialTool != nil }
    var hasSettings: Bool { hasActiveTool || selectedAnnotationID != nil || selectedSpecialID != nil }
    var settingsTool: ScreenshotSupport.Tool? {
        tool ?? selectedAnnotationID.flatMap { id in annotations.first { $0.id == id }?.tool }
    }
    var settingsSpecialTool: InlineSpecialTool? {
        specialTool ?? selectedSpecialID.flatMap { id in specialMarks.first { $0.id == id }?.kind }
    }

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: InlineCapturePreferenceKey.color),
           let value = ScreenshotSupport.ColorID(rawValue: raw) { color = value }
        if let raw = defaults.string(forKey: InlineCapturePreferenceKey.stroke),
           let value = ScreenshotSupport.StrokeID(rawValue: raw) { stroke = value }
        if let raw = defaults.string(forKey: InlineCapturePreferenceKey.lineStyle),
           let value = ScreenshotSupport.LineStyle(rawValue: raw) { lineStyle = value }
        if defaults.object(forKey: InlineCapturePreferenceKey.filled) != nil {
            filled = defaults.bool(forKey: InlineCapturePreferenceKey.filled)
        }
        if let raw = defaults.string(forKey: InlineCapturePreferenceKey.arrowStyle),
           let value = ScreenshotSupport.ArrowStyle(rawValue: raw) { arrowStyle = value }
        if let raw = defaults.string(forKey: InlineCapturePreferenceKey.mosaicMode),
           let value = ScreenshotSupport.MosaicMode(rawValue: raw) { mosaicMode = value }
        if let raw = defaults.string(forKey: InlineCapturePreferenceKey.magnifierShape),
           let value = ScreenshotSupport.MagnifierShape(rawValue: raw) { magnifierShape = value }
        if defaults.object(forKey: InlineCapturePreferenceKey.magnifierZoom) != nil {
            magnifierZoom = min(3, max(1.2,
                defaults.double(forKey: InlineCapturePreferenceKey.magnifierZoom)))
        }
        if let raw = defaults.string(forKey: InlineCapturePreferenceKey.fontDesign),
           let value = InlineFontDesign(rawValue: raw) { fontDesign = value }
        if defaults.object(forKey: InlineCapturePreferenceKey.bold) != nil {
            bold = defaults.bool(forKey: InlineCapturePreferenceKey.bold)
        }
        if defaults.object(forKey: InlineCapturePreferenceKey.fontSize) != nil {
            fontSize = defaults.double(forKey: InlineCapturePreferenceKey.fontSize)
        }
    }

    private var isSynchronizingSelection = false

    private func synchronizeFromSelectedAnnotation() {
        guard let id = selectedAnnotationID,
              let mark = annotations.first(where: { $0.id == id }) else { return }
        isSynchronizingSelection = true
        color = mark.color; stroke = mark.stroke; lineStyle = mark.lineStyle
        filled = mark.filled; arrowStyle = mark.arrowStyle
        isSynchronizingSelection = false
    }

    private func synchronizeFromSelectedSpecial() {
        guard let id = selectedSpecialID,
              let mark = specialMarks.first(where: { $0.id == id }) else { return }
        isSynchronizingSelection = true
        color = mark.color; stroke = mark.stroke
        magnifierShape = mark.magnifierShape; magnifierZoom = Double(mark.magnifierZoom)
        fontDesign = mark.fontDesign; bold = mark.bold; fontSize = Double(mark.fontSize)
        lineStyle = mark.lineStyle; inputText = mark.text
        isSynchronizingSelection = false
    }

    private func mutateSelectedAnnotation(_ mutation: (inout ScreenshotSupport.Annotation) -> Void) {
        guard !isSynchronizingSelection, let id = selectedAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        history.append(.mutation(annotations[index]))
        mutation(&annotations[index])
    }

    private func mutateSelectedSpecial(_ mutation: (inout InlineSpecialMark) -> Void) {
        guard !isSynchronizingSelection, let id = selectedSpecialID,
              let index = specialMarks.firstIndex(where: { $0.id == id }) else { return }
        history.append(.specialMutation(specialMarks[index]))
        mutation(&specialMarks[index])
    }

    private func applyColorToSelection() {
        mutateSelectedAnnotation { $0.color = color }
        mutateSelectedSpecial { $0.color = color }
    }

    private func applyStrokeToSelection() {
        mutateSelectedAnnotation { $0.stroke = stroke }
        mutateSelectedSpecial { $0.stroke = stroke }
    }

    func activate(_ tool: ScreenshotSupport.Tool?) {
        selectedAnnotationID = nil
        selectedSpecialID = nil
        self.tool = self.tool == tool ? nil : tool
        specialTool = nil
    }

    func activate(_ special: InlineSpecialTool) {
        selectedAnnotationID = nil
        selectedSpecialID = nil
        if special == .watermark {
            history.append(.watermark(watermarkEnabled))
            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = "水印"
            }
            if specialTool == .watermark {
                watermarkEnabled.toggle()
                specialTool = watermarkEnabled ? .watermark : nil
            } else {
                watermarkEnabled = true
                specialTool = .watermark
            }
        } else {
            specialTool = specialTool == special ? nil : special
        }
        tool = nil
    }

    func addText(_ text: String, at point: CGPoint, width: CGFloat = 188) {
        let mark = InlineSpecialMark(id: UUID(), kind: .text, start: point, end: point,
                                     text: text, color: color, stroke: stroke,
                                     lineStyle: lineStyle,
                                     magnifierShape: magnifierShape,
                                     magnifierZoom: CGFloat(magnifierZoom),
                                     fontDesign: fontDesign, bold: bold,
                                     fontSize: CGFloat(fontSize), textWidth: max(120, width))
        specialMarks.append(mark)
        selectedSpecialID = mark.id
        selectedAnnotationID = nil
        history.append(.special(mark.id))
    }

    func editableSpecialMark(at point: CGPoint) -> InlineSpecialMark? {
        specialMarks.reversed().first {
            ($0.kind == .text || $0.kind == .note) && specialHitTest($0, at: point)
        }
    }

    func updateSpecialText(id: UUID, text: String) {
        guard let index = specialMarks.firstIndex(where: { $0.id == id }),
              specialMarks[index].text != text else { return }
        history.append(.specialMutation(specialMarks[index]))
        specialMarks[index].text = text
        selectedSpecialID = id
        inputText = text
    }

    func updateSpecialWidth(id: UUID, width: CGFloat) {
        guard let index = specialMarks.firstIndex(where: { $0.id == id }) else { return }
        specialMarks[index].textWidth = max(120, width)
    }

    @discardableResult
    func deleteSelection() -> Bool {
        if let id = selectedAnnotationID,
           let index = annotations.firstIndex(where: { $0.id == id }) {
            history.append(.deletedAnnotation(annotations[index]))
            annotations.remove(at: index)
            selectedAnnotationID = nil
            return true
        }
        if let id = selectedSpecialID,
           let index = specialMarks.firstIndex(where: { $0.id == id }) {
            history.append(.deletedSpecial(specialMarks[index]))
            specialMarks.remove(at: index)
            selectedSpecialID = nil
            return true
        }
        return false
    }

    func begin(at point: CGPoint) {
        if let specialTool {
            start = point
            if specialTool == .watermark { return }
            let mark = InlineSpecialMark(id: UUID(), kind: specialTool, start: point, end: point,
                                   text: inputText.isEmpty ? defaultText(for: specialTool) : inputText,
                                   color: color, stroke: stroke, lineStyle: lineStyle,
                                   magnifierShape: magnifierShape,
                                   magnifierZoom: CGFloat(magnifierZoom),
                                   fontDesign: fontDesign, bold: bold,
                                   fontSize: CGFloat(fontSize))
            specialMarks.append(mark)
            specialDraftID = mark.id
            pendingNotePlacement = specialTool == .note
            history.append(.special(mark.id))
            return
        }
        guard let tool else { return }
        start = point
        let annotation: ScreenshotSupport.Annotation
        switch tool {
        case .arrow, .line:
            annotation = .init(tool: tool, points: [point, point], color: color, stroke: stroke,
                               lineStyle: lineStyle, arrowStyle: arrowStyle)
        case .freehand, .highlight:
            annotation = .init(tool: tool, points: [point], color: color, stroke: stroke,
                               lineStyle: lineStyle)
        case .pixelate where mosaicMode == .brush:
            annotation = .init(tool: tool, points: [point], color: color, stroke: stroke)
        case .rect, .ellipse, .pixelate:
            annotation = .init(tool: tool, rect: CGRect(origin: point, size: .zero),
                               color: color, stroke: stroke, lineStyle: lineStyle, filled: filled)
        case .counter:
            let side = ScreenshotSupport.counterDiameter(
                for: CGSize(width: 1_000, height: 1_000), scale: 1, stroke: stroke)
            annotation = .init(tool: .counter,
                               rect: CGRect(x: point.x - side / 2, y: point.y - side / 2,
                                            width: side, height: side),
                               color: color, stroke: stroke, number: annotations.filter {
                                   $0.tool == .counter
                               }.count + 1)
        default:
            return
        }
        annotations.append(annotation)
        draftID = annotation.id
        selectedAnnotationID = annotation.id
        selectedSpecialID = nil
        history.append(.annotation(annotation.id))
    }

    func beginAdjustment(at point: CGPoint) -> Bool {
        if let selectedAnnotationID,
           let selected = annotations.first(where: { $0.id == selectedAnnotationID }) {
            if selected.points.count >= 2 {
                if hypot(point.x - selected.points[0].x, point.y - selected.points[0].y) <= 10 {
                    beginAdjustment(selected, handle: .topLeft, at: point); return true
                }
                if hypot(point.x - selected.points[1].x, point.y - selected.points[1].y) <= 10 {
                    beginAdjustment(selected, handle: .bottomRight, at: point); return true
                }
            } else if let handle = ScreenshotSupport.handle(at: point, rect: selected.rect,
                                                            tolerance: 9) {
                beginAdjustment(selected, handle: handle, at: point); return true
            }
        }
        guard let hit = annotations.reversed().first(where: { hitTest($0, at: point) }) else {
            selectedAnnotationID = nil
            return beginSpecialAdjustment(at: point)
        }
        selectedAnnotationID = hit.id
        beginAdjustment(hit, handle: nil, at: point)
        return true
    }

    private func beginSpecialAdjustment(at point: CGPoint) -> Bool {
        let candidates = specialMarks.reversed()
        guard let mark = candidates.first(where: { specialHitTest($0, at: point) }) else {
            selectedSpecialID = nil
            return false
        }
        selectedSpecialID = mark.id
        adjustingSpecialID = mark.id
        specialAdjustmentStart = point
        specialAdjustmentOriginal = mark
        specialAdjustmentHandle = nil
        if mark.kind == .note {
            let box = inlineNoteRect(mark)
            let widthHandle = CGPoint(x: box.maxX, y: box.midY)
            specialNoteWidthAdjustment = hypot(point.x - widthHandle.x,
                                               point.y - widthHandle.y) <= 10
            if box.contains(point), !specialNoteWidthAdjustment {
                specialAdjustmentEndpoint = 1
            }
        } else { specialNoteWidthAdjustment = false }
        let nearStart = hypot(point.x - mark.start.x, point.y - mark.start.y) <= 10
        let nearEnd = hypot(point.x - mark.end.x, point.y - mark.end.y) <= 10
        let nearMagnifierHandle: Bool
        if mark.kind == .magnifier {
            let radius = max(68, hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y))
            let rect = CGRect(x: mark.start.x - radius, y: mark.start.y - radius,
                              width: radius * 2, height: radius * 2)
            nearMagnifierHandle = ScreenshotSupport.Handle.allCases.contains {
                let handle = $0.position(in: rect)
                return hypot(point.x - handle.x, point.y - handle.y) <= 10
            }
        } else { nearMagnifierHandle = false }
        if mark.kind == .text {
            let box = inlineTextRect(mark)
            let nearLeft = hypot(point.x - box.minX, point.y - box.midY) <= 10
            let nearRight = hypot(point.x - box.maxX, point.y - box.midY) <= 10
            specialAdjustmentEndpoint = nearLeft ? 0 : (nearRight ? 1 : nil)
        } else if !(mark.kind == .note && inlineNoteRect(mark).contains(point)
                    && !specialNoteWidthAdjustment) {
            specialAdjustmentEndpoint = !specialNoteWidthAdjustment && nearStart
                && mark.kind != .magnifier ? 0
                : ((nearEnd || nearMagnifierHandle) ? 1 : nil)
        }
        adjustmentRecorded = false
        return true
    }

    private func specialHitTest(_ mark: InlineSpecialMark, at point: CGPoint) -> Bool {
        switch mark.kind {
        case .text:
            return inlineTextRect(mark).insetBy(dx: -7, dy: -7).contains(point)
        case .note:
            return inlineNoteRect(mark).insetBy(dx: -7, dy: -7).contains(point)
                || ScreenshotSupport.distance(from: point, toSegment: mark.start, mark.end) <= 9
        case .magnifier:
            let radius = max(68, hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y))
            return hypot(point.x - mark.start.x, point.y - mark.start.y) <= radius + 8
        case .watermark:
            return false
        }
    }

    private func beginAdjustment(_ annotation: ScreenshotSupport.Annotation,
                                 handle: ScreenshotSupport.Handle?, at point: CGPoint) {
        adjustingAnnotationID = annotation.id
        adjustmentHandle = handle
        adjustmentStart = point
        adjustmentRect = annotation.rect
        adjustmentPoints = annotation.points
        adjustmentRecorded = false
    }

    private func hitTest(_ annotation: ScreenshotSupport.Annotation, at point: CGPoint) -> Bool {
        if annotation.points.count >= 2 {
            if annotation.tool == .freehand || annotation.tool == .highlight {
                for index in 1..<annotation.points.count where
                    ScreenshotSupport.distance(from: point,
                                               toSegment: annotation.points[index - 1],
                                               annotation.points[index]) <= 9 { return true }
                return false
            }
            return ScreenshotSupport.distance(from: point,
                                               toSegment: annotation.points[0],
                                               annotation.points[1]) <= 9
        }
        if annotation.tool == .counter {
            let radius = max(annotation.rect.width, annotation.rect.height) / 2
            return hypot(point.x - annotation.rect.midX,
                         point.y - annotation.rect.midY) <= radius + 7
        }
        return annotation.rect.insetBy(dx: -7, dy: -7).contains(point)
    }

    func drag(to point: CGPoint) {
        if let adjustingSpecialID,
           let index = specialMarks.firstIndex(where: { $0.id == adjustingSpecialID }),
           let original = specialAdjustmentOriginal {
            if !adjustmentRecorded {
                history.append(.specialMutation(original)); adjustmentRecorded = true
            }
            if original.kind == .text, specialAdjustmentEndpoint == 0 {
                let fixedRight = original.start.x + original.textWidth
                specialMarks[index].start.x = min(point.x, fixedRight - 120)
                specialMarks[index].textWidth = fixedRight - specialMarks[index].start.x
            } else if original.kind == .text, specialAdjustmentEndpoint == 1 {
                specialMarks[index].textWidth = max(120, point.x - original.start.x)
            } else if specialNoteWidthAdjustment, original.kind == .note {
                let box = inlineNoteRect(original)
                specialMarks[index].textWidth = max(120, point.x - box.minX)
            } else if let handle = specialAdjustmentHandle, original.kind == .text {
                let resized = ScreenshotSupport.resizedRect(
                    inlineTextRect(original), dragging: handle, to: point)
                specialMarks[index].start = resized.origin
                specialMarks[index].end = CGPoint(x: resized.maxX, y: resized.maxY)
            } else if specialAdjustmentEndpoint == 0 { specialMarks[index].start = point }
            else if specialAdjustmentEndpoint == 1 { specialMarks[index].end = point }
            else {
                let delta = CGPoint(x: point.x - specialAdjustmentStart.x,
                                    y: point.y - specialAdjustmentStart.y)
                specialMarks[index].start = CGPoint(x: original.start.x + delta.x,
                                                     y: original.start.y + delta.y)
                specialMarks[index].end = CGPoint(x: original.end.x + delta.x,
                                                   y: original.end.y + delta.y)
            }
            return
        }
        if let adjustingAnnotationID,
           let index = annotations.firstIndex(where: { $0.id == adjustingAnnotationID }) {
            if !adjustmentRecorded {
                history.append(.mutation(annotations[index]))
                adjustmentRecorded = true
            }
            if let adjustmentHandle {
                if adjustmentPoints.count >= 2 {
                    var points = adjustmentPoints
                    if adjustmentHandle == .topLeft { points[0] = point } else { points[1] = point }
                    annotations[index].points = points
                } else {
                    annotations[index].rect = ScreenshotSupport.resizedRect(
                        adjustmentRect, dragging: adjustmentHandle, to: point)
                }
            } else {
                let delta = CGPoint(x: point.x - adjustmentStart.x, y: point.y - adjustmentStart.y)
                annotations[index].rect = adjustmentRect.offsetBy(dx: delta.x, dy: delta.y)
                annotations[index].points = adjustmentPoints.map {
                    CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
                }
            }
            return
        }
        if let specialDraftID,
           let index = specialMarks.firstIndex(where: { $0.id == specialDraftID }) {
            specialMarks[index].end = point
            if specialMarks[index].kind == .note { pendingNotePlacement = false }
            return
        }
        guard let draftID, let index = annotations.firstIndex(where: { $0.id == draftID }) else { return }
        switch annotations[index].tool {
        case .arrow, .line: annotations[index].points = [start, point]
        case .freehand, .highlight: annotations[index].points.append(point)
        case .pixelate where !annotations[index].points.isEmpty:
            annotations[index].points.append(point)
        case .rect, .ellipse, .pixelate:
            annotations[index].rect = ScreenshotSupport.selectionRect(from: start, to: point)
        case .counter:
            annotations[index].rect = ScreenshotSupport.selectionRect(from: start, to: point,
                                                                       square: true)
        default: break
        }
    }

    @discardableResult
    func end(at point: CGPoint) -> InlineSpecialMark? {
        if adjustingAnnotationID != nil {
            adjustingAnnotationID = nil
            adjustmentHandle = nil
            adjustmentRecorded = false
            return nil
        }
        if adjustingSpecialID != nil {
            adjustingSpecialID = nil
            specialAdjustmentOriginal = nil
            specialAdjustmentEndpoint = nil
            specialAdjustmentHandle = nil
            specialNoteWidthAdjustment = false
            adjustmentRecorded = false
            return nil
        }
        if let specialDraftID {
            if pendingNotePlacement {
                // A click fixes the leader's anchor. The callout follows the
                // pointer until the second click chooses its text-box position.
                return nil
            }
            if let index = specialMarks.firstIndex(where: { $0.id == specialDraftID }),
               specialMarks[index].kind == .text {
                let dragged = ScreenshotSupport.selectionRect(
                    from: specialMarks[index].start, to: specialMarks[index].end)
                specialMarks[index].start = CGPoint(
                    x: min(specialMarks[index].start.x, specialMarks[index].end.x),
                    y: min(specialMarks[index].start.y, specialMarks[index].end.y))
                specialMarks[index].textWidth = max(120, dragged.width)
                let rect = inlineTextRect(specialMarks[index])
                specialMarks[index].end = CGPoint(x: rect.maxX, y: rect.maxY)
            }
            let completed = specialMarks.first(where: { $0.id == specialDraftID })
            self.specialDraftID = nil
            pendingNotePlacement = false
            if completed?.kind == .text || completed?.kind == .note { specialTool = nil }
            return completed
        }
        guard let draftID, let index = annotations.firstIndex(where: { $0.id == draftID }) else {
            self.draftID = nil
            return nil
        }
        let mark = annotations[index]
        if mark.tool == .counter, min(mark.rect.width, mark.rect.height) < 10 {
            let side = ScreenshotSupport.counterDiameter(
                for: CGSize(width: 1_000, height: 1_000), scale: 1, stroke: mark.stroke)
            annotations[index].rect = CGRect(x: start.x - side / 2, y: start.y - side / 2,
                                             width: side, height: side)
        }
        if mark.tool == .counter { tool = nil }
        if mark.tool != .counter,
           mark.rect.width < 2, mark.rect.height < 2,
           mark.points.count < 2 || (mark.points.first == mark.points.last) {
            annotations.remove(at: index)
            history.removeAll {
                if case .annotation(let id) = $0 { return id == draftID }
                return false
            }
        }
        self.draftID = nil
        return nil
    }

    func previewPendingNote(to point: CGPoint) {
        guard pendingNotePlacement, let id = specialDraftID,
              let index = specialMarks.firstIndex(where: { $0.id == id }) else { return }
        specialMarks[index].end = point
    }

    func commitPendingNote(at point: CGPoint) {
        previewPendingNote(to: point)
        pendingNotePlacement = false
    }

    func undo() {
        guard let item = history.popLast() else { return }
        switch item {
        case .annotation(let id): annotations.removeAll { $0.id == id }
        case .special(let id): specialMarks.removeAll { $0.id == id }
        case .mutation(let old):
            if let index = annotations.firstIndex(where: { $0.id == old.id }) {
                annotations[index] = old
            }
        case .specialMutation(let old):
            if let index = specialMarks.firstIndex(where: { $0.id == old.id }) {
                specialMarks[index] = old
            }
        case .deletedAnnotation(let old):
            annotations.append(old); selectedAnnotationID = old.id
        case .deletedSpecial(let old):
            specialMarks.append(old); selectedSpecialID = old.id
        case .watermark(let previous): watermarkEnabled = previous
        }
    }

    var canUndo: Bool { !history.isEmpty }

    private func defaultText(for tool: InlineSpecialTool) -> String {
        switch tool {
        case .text: return "文本"
        case .note: return "备注"
        case .watermark: return "水印"
        case .magnifier: return ""
        }
    }

    var payload: InlineCapturePayload {
        InlineCapturePayload(annotations: annotations,
                             specialMarks: specialMarks,
                             watermarkText: watermarkEnabled ? inputText : "",
                             watermarkColor: color,
                             watermarkStroke: stroke,
                             watermarkOpacity: CGFloat(watermarkOpacity),
                             watermarkAngle: CGFloat(watermarkAngle),
                             watermarkScale: CGFloat(watermarkScale),
                             watermarkSpacing: CGFloat(watermarkSpacing),
                             fontDesign: fontDesign,
                             bold: bold)
    }
}

private struct InlineCaptureToolbar: View {
    // Main row: 36 pt buttons + 4 pt group padding on both sides.
    // The outer material uses exactly 8 pt on all four edges.
    static func contentHeight(hasSettings: Bool) -> CGFloat {
        44 + 16 + (hasSettings ? 7 + 34 : 0)
    }
    @ObservedObject var state: InlineCaptureEditorState
    let canScrollCapture: Bool
    let scrollCapture: () -> Void
    let cancel: () -> Void
    let save: () -> Void
    let confirm: () -> Void
    @State private var hoverTip: String?
    @State private var hoverPoint: CGPoint = .zero
    @State private var pendingHoverTitle: String?
    @State private var hoverTask: Task<Void, Never>?

    private struct ToolItem: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let base: ScreenshotSupport.Tool?
        let special: InlineSpecialTool?
    }

    private let tools: [ToolItem] = [
        .init(id: "rect", symbol: "rectangle", title: "矩形", base: .rect, special: nil),
        .init(id: "ellipse", symbol: "circle", title: "椭圆", base: .ellipse, special: nil),
        .init(id: "line", symbol: "line.diagonal", title: "直线", base: .line, special: nil),
        .init(id: "arrow", symbol: "arrow.up.right", title: "箭头", base: .arrow, special: nil),
        .init(id: "freehand", symbol: "scribble.variable", title: "画笔", base: .freehand, special: nil),
        .init(id: "highlight", symbol: "highlighter", title: "荧光笔", base: .highlight, special: nil),
        .init(id: "text", symbol: "character.cursor.ibeam", title: "文本", base: nil, special: .text),
        .init(id: "counter", symbol: "1.circle", title: "标点", base: .counter, special: nil),
        .init(id: "note", symbol: "note.text", title: "备注", base: nil, special: .note),
        .init(id: "pixelate", symbol: "square.grid.3x3.fill", title: "马赛克", base: .pixelate, special: nil),
        .init(id: "magnifier", symbol: "plus.magnifyingglass", title: "放大镜", base: nil, special: .magnifier),
        .init(id: "watermark", symbol: "textformat.abc.dottedunderline", title: "文字水印", base: nil, special: .watermark),
    ]

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                toolGroup("绘图", items: Array(tools[0...5]))
                toolGroup("标注", items: Array(tools[6...8]))
                toolGroup("效果", items: Array(tools[9...11]))
                actionGroup
            }
            if state.hasSettings { optionRow.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(8)
        .frame(height: Self.contentHeight(hasSettings: state.hasSettings), alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .coordinateSpace(name: "inlineCaptureToolbar")
        .overlay(alignment: .topLeading) {
            if let hoverTip {
                Text(hoverTip)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.97),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.primary.opacity(0.16))
                    }
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .fixedSize()
                    // Keep the explanation outside the toolbar chrome, directly
                    // above the hovered button in the same vertical column.
                    .position(x: hoverPoint.x, y: -16)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }

    private func toolGroup(_: String, items: [ToolItem]) -> some View {
        HStack(spacing: 6) {
            ForEach(items) { tool in
                hoverTracked(tool.title, width: 36) {
                    Button { select(tool) } label: {
                        ScreenshotToolIcon(symbol: tool.symbol)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                            .background(isSelected(tool)
                                        ? Color.accentColor.opacity(0.22) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .screenshotSafeHelp(tool.title)
                    .accessibilityLabel(tool.title)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private var actionGroup: some View {
        HStack(spacing: 6) {
                if canScrollCapture {
                    hoverTracked("滚动截图", width: 36) {
                        Button(action: scrollCapture) {
                            ScrollCaptureIcon()
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("滚动截图")
                    }
                }
                hoverTracked("撤销", width: 36) {
                    Button(action: state.undo) {
                        ScreenshotToolIcon(symbol: "arrow.uturn.backward").frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!state.canUndo)
                }
                hoverTracked("取消截图", width: 36) {
                    Button(action: cancel) {
                        ScreenshotToolIcon(symbol: "xmark").frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                hoverTracked("保存到下载目录", width: 36) {
                    Button(action: save) {
                        ScreenshotToolIcon(symbol: "square.and.arrow.down").frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                hoverTracked("完成并复制", width: 36) {
                    Button(action: confirm) {
                        ScreenshotToolIcon(symbol: "checkmark").frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private func hoverTracked<Content: View>(_ title: String,
                                             width: CGFloat,
                                             @ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { proxy in
            content()
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let frame = proxy.frame(in: .named("inlineCaptureToolbar"))
                        hoverPoint = CGPoint(x: frame.minX + point.x,
                                             y: frame.minY + point.y)
                        if hoverTip != title, pendingHoverTitle != title {
                            hoverTask?.cancel()
                            pendingHoverTitle = title
                            hoverTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 550_000_000)
                                guard !Task.isCancelled, pendingHoverTitle == title else { return }
                                hoverTip = title
                            }
                        }
                    case .ended:
                        hoverTask?.cancel()
                        pendingHoverTitle = nil
                        if hoverTip == title { hoverTip = nil }
                    }
                }
        }
        .frame(width: width, height: 36)
    }

    private func select(_ item: ToolItem) {
        if let base = item.base { state.activate(base) }
        else if let special = item.special { state.activate(special) }
    }

    private func isSelected(_ item: ToolItem) -> Bool {
        item.base.map { state.tool == $0 }
            ?? item.special.map { $0 == .watermark ? state.watermarkEnabled : state.specialTool == $0 }
            ?? false
    }

    private var optionRow: some View {
        HStack(spacing: 8) {
            ForEach(ScreenshotSupport.ColorID.allCases, id: \.self) { color in
                Button { state.color = color } label: {
                    Circle().fill(Color(nsColor: ScreenshotRenderer.nsColor(color)))
                        .frame(width: 14, height: 14)
                        .overlay { Circle().stroke(.primary, lineWidth: state.color == color ? 2 : 0) }
                }.buttonStyle(.plain)
            }
            if state.settingsSpecialTool != .text {
                Picker("线宽", selection: $state.stroke) {
                    Text("细").tag(ScreenshotSupport.StrokeID.small)
                    Text("中").tag(ScreenshotSupport.StrokeID.medium)
                    Text("粗").tag(ScreenshotSupport.StrokeID.large)
                }.labelsHidden().frame(width: 68)
            }
            if state.settingsTool == .rect || state.settingsTool == .ellipse {
                Toggle("填充", isOn: $state.filled).toggleStyle(.button).controlSize(.mini)
            }
            if state.settingsTool == .rect || state.settingsTool == .ellipse || state.settingsTool == .line
                || state.settingsTool == .arrow || state.settingsTool == .freehand || state.settingsTool == .highlight {
                Picker("线型", selection: $state.lineStyle) {
                    Text("实线").tag(ScreenshotSupport.LineStyle.solid)
                    Text("虚线").tag(ScreenshotSupport.LineStyle.dashed)
                    Text("点线").tag(ScreenshotSupport.LineStyle.dotted)
                }.labelsHidden().frame(width: 72)
            }
            if state.settingsTool == .arrow {
                Picker("箭头", selection: $state.arrowStyle) {
                    Text("实心").tag(ScreenshotSupport.ArrowStyle.filled)
                    Text("空心").tag(ScreenshotSupport.ArrowStyle.open)
                    Text("双向").tag(ScreenshotSupport.ArrowStyle.double)
                }.labelsHidden().frame(width: 72)
            }
            if state.settingsTool == .pixelate {
                Picker("马赛克", selection: $state.mosaicMode) {
                    Text("区域").tag(ScreenshotSupport.MosaicMode.rectangle)
                    Text("画笔").tag(ScreenshotSupport.MosaicMode.brush)
                }.labelsHidden().frame(width: 72)
            }
            if state.settingsSpecialTool == .magnifier {
                Picker("形状", selection: $state.magnifierShape) {
                    Text("圆形").tag(ScreenshotSupport.MagnifierShape.circle)
                    Text("方形").tag(ScreenshotSupport.MagnifierShape.rectangle)
                }.labelsHidden().frame(width: 72)
            }
            if state.settingsSpecialTool == .text || state.settingsSpecialTool == .note || state.settingsSpecialTool == .watermark {
                if state.settingsSpecialTool != .watermark {
                    Picker("字号", selection: $state.fontSize) {
                        ForEach([12.0, 14, 16, 18, 24, 32, 48, 64], id: \.self) {
                            Text("\(Int($0)) pt").tag($0)
                        }
                    }.frame(width: 82)
                }
                Picker("字体", selection: $state.fontDesign) {
                    Text("系统").tag(InlineFontDesign.system)
                    Text("衬线").tag(InlineFontDesign.serif)
                    Text("等宽").tag(InlineFontDesign.monospaced)
                }.labelsHidden().frame(width: 72)
                Toggle("粗体", isOn: $state.bold).toggleStyle(.button).controlSize(.mini)
                if state.settingsSpecialTool == .note {
                    Picker("引线样式", selection: $state.lineStyle) {
                        Text("实线").tag(ScreenshotSupport.LineStyle.solid)
                        Text("虚线").tag(ScreenshotSupport.LineStyle.dashed)
                        Text("点线").tag(ScreenshotSupport.LineStyle.dotted)
                    }.labelsHidden().frame(width: 72)
                }
                TextField(state.settingsSpecialTool == .note ? "备注内容"
                          : (state.settingsSpecialTool == .watermark ? "水印文字" : "文字内容"),
                          text: $state.inputText)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
            }
            if state.settingsSpecialTool == .magnifier {
                Slider(value: $state.magnifierZoom, in: 1.2...3).frame(width: 96)
                Text(String(format: "%.1f×", state.magnifierZoom)).monospacedDigit()
            }
            if state.settingsSpecialTool == .watermark {
                Slider(value: $state.watermarkOpacity, in: 0.08...0.8).frame(width: 90)
                Slider(value: $state.watermarkAngle, in: -60...60).frame(width: 78)
                Slider(value: $state.watermarkScale, in: 0.6...2).frame(width: 70)
                Slider(value: $state.watermarkSpacing, in: 0.6...2).frame(width: 70)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

}
