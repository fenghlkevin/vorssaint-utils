// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// One monochrome vector size for screenshot tools and result actions.
struct ScreenshotToolIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .resizable().scaledToFit()
            .fontWeight(.medium)
            .symbolRenderingMode(.monochrome)
            .frame(width: 18, height: 18)
            .foregroundStyle(.primary)
    }
}

/// Shared capture glyph: a framed pair of chevrons, rotated for horizontal capture.
struct ScrollCaptureIcon: View {
    var horizontal = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .stroke(lineWidth: 1.7)
                .frame(width: 14, height: 18)
            Path { path in
                for y in [6.0, 11.0] {
                    path.move(to: CGPoint(x: 6, y: y))
                    path.addLine(to: CGPoint(x: 10, y: y + 3))
                    path.addLine(to: CGPoint(x: 14, y: y))
                }
            }
            .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 20, height: 20)
        .rotationEffect(.degrees(horizontal ? -90 : 0))
        .scaleEffect(0.9)
        .frame(width: 18, height: 18)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}

/// Small floating confirmation used by the quick tools (color picked, text
/// copied, mic muted): a non-activating panel near the top of the screen with
/// the mouse, fading out on its own. Purely visual; never takes focus.
enum QuickToolHUD {
    private static var panel: NSPanel?
    private static var scrollingPanel: ScrollingCapturePanel?
    private static var scrollingPreviewPanel: NSPanel?
    private static var scrollingModel: ScrollingCaptureHUDModel?
    private static var dismissWork: DispatchWorkItem?
    /// How wide a message is allowed to get, on either of this file's two
    /// message panels. A confirmation is read at a
    /// glance, so anything past this is a preview rather than the whole value;
    /// a short one still sizes to itself and is not padded out to this width.
    fileprivate static let messageWidthLimit: CGFloat = 360
    /// Bumped by every show(). A dismiss whose fade-out was overtaken by a
    /// newer show() must not order the panel out from its completion handler.
    private static var generation = 0

    /// The confirmation panel, when one is on screen. A recording in progress
    /// leaves it out of the picture; nothing else needs to know it exists.
    static var currentWindowNumber: Int? {
        guard let panel, panel.isVisible else { return nil }
        return panel.windowNumber
    }

    /// The scrolling capture controls, when they are on screen. They belong to
    /// the capture in progress and must stay out of its own pictures.
    static var currentScrollingWindowNumber: Int? {
        guard let scrollingPanel, scrollingPanel.isVisible else { return nil }
        return scrollingPanel.windowNumber
    }

    static var scrollingToolbarFrame: CGRect { scrollingPanel?.frame ?? .zero }

    static var currentScrollingWindowNumbers: Set<CGWindowID> {
        var result: Set<CGWindowID> = []
        if let panel = scrollingPanel, panel.isVisible, panel.windowNumber > 0 {
            result.insert(CGWindowID(panel.windowNumber))
        }
        if let panel = scrollingPreviewPanel, panel.isVisible, panel.windowNumber > 0 {
            result.insert(CGWindowID(panel.windowNumber))
        }
        return result
    }

    static func show(icon: String, message: String, swatch: NSColor? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { show(icon: icon, message: message, swatch: swatch) }
            return
        }
        let content = HStack(spacing: 8) {
            if let swatch {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: swatch))
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                // What was copied can be a whole paragraph, and the panel is
                // laid out at whatever the text asks for. Unbounded, one long
                // line measures wider than the screen and the panel, centred on
                // that width, hangs off both edges with nothing readable left.
                //
                // Truncating at the tail rather than the middle so that the
                // ellipsis is always drawn: a value whose first paragraph ends
                // on the second line is cut at a line break, not inside one,
                // and middle truncation leaves no mark at all there — the
                // preview then reads as the whole of what was copied.
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: messageWidthLimit, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        present(AnyView(content), dismissAfter: 1.5)
    }

    static func showCountdown(_ value: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { showCountdown(value) }
            return
        }
        let startedAt = Date()
        let content = TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let progress = ScreenshotSupport.countdownRingProgress(
                elapsed: context.date.timeIntervalSince(startedAt))
            QuickToolCountdownView(value: value, progress: progress)
        }
        .frame(width: 82, height: 82)
        .background(.regularMaterial, in: Circle())
        .padding(12)

        present(AnyView(content), dismissAfter: 0.92, windowShadow: false)
    }

    /// The scrolling capture stays visible while the person moves the target.
    /// Its non-activating panel takes key focus only so Return and Escape do
    /// not leak into the page being captured.
    static func showScrollingCapture(message: String,
                                     finishTitle: String,
                                     cancelTitle: String,
                                     anchorRect: CGRect,
                                     onAxisChange: @escaping (ScrollingImageStitcher.Axis) -> Void,
                                     onFinish: @escaping () -> Void,
                                     onCancel: @escaping () -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                showScrollingCapture(message: message,
                                     finishTitle: finishTitle,
                                     cancelTitle: cancelTitle,
                                     anchorRect: anchorRect,
                                     onAxisChange: onAxisChange,
                                     onFinish: onFinish,
                                     onCancel: onCancel)
            }
            return
        }
        let screenFrame = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) })?
            .frame ?? NSScreen.pointerVisibleFrame
        let leftRoom = anchorRect.minX - screenFrame.minX
        let rightRoom = screenFrame.maxX - anchorRect.maxX
        let previewOnLeft = leftRoom >= rightRoom
        let availableWidth = max(120, (previewOnLeft ? leftRoom : rightRoom) - 12)
        let previewWidth = min(anchorRect.width, availableWidth)
        let previewHeight = min(anchorRect.height,
                                previewWidth / max(anchorRect.width, 1) * anchorRect.height)
        let previewRect = CGRect(x: previewOnLeft
                                    ? anchorRect.minX - previewWidth - 8
                                    : anchorRect.maxX + 8,
                                 y: anchorRect.midY - previewHeight / 2,
                                 width: previewWidth, height: previewHeight)
        let model = ScrollingCaptureHUDModel(message: message,
                                             screenFrame: screenFrame,
                                             liveRect: anchorRect,
                                             previewRect: previewRect)
        scrollingModel = model
        let content = ScrollingCaptureHUDView(model: model,
                                              finishTitle: finishTitle,
                                              cancelTitle: cancelTitle,
                                              onAxisChange: onAxisChange,
                                              onFinish: onFinish,
                                              onCancel: onCancel)
        let host = NSHostingController(rootView: AnyView(content))
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let panel = ensureScrollingPanel()
        panel.contentViewController = host
        let x = min(max(anchorRect.maxX - size.width, screenFrame.minX + 8),
                    screenFrame.maxX - size.width - 8)
        var y = anchorRect.minY - size.height - 10
        if y < screenFrame.minY + 8 { y = anchorRect.maxY + 10 }
        panel.setFrame(NSRect(x: x,
                              y: y,
                              width: size.width,
                              height: size.height),
                       display: true)
        panel.orderFrontRegardless()
        panel.makeKey()

        let preview = ensureScrollingPreviewPanel()
        preview.setFrame(screenFrame, display: true)
        preview.contentViewController = NSHostingController(rootView:
            ScrollingCapturePreviewView(model: model))
        preview.orderFrontRegardless()
    }

    static func updateScrollingCapture(height: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { updateScrollingCapture(height: height) }
            return
        }
        scrollingModel?.height = height
    }

    static func updateScrollingCapture(progress: ScreenshotScrollingCapture.Progress) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { updateScrollingCapture(progress: progress) }
            return
        }
        scrollingModel?.height = progress.pixelLength
        scrollingModel?.currentFrame = progress.currentFrame
        if let model = scrollingModel,
           model.preview == nil || progress.acceptedFrames > model.acceptedFrames {
            // A sampling tick may carry a current frame while overlap matching
            // is still pending. Never let that tick replace the committed
            // stitched image; advance the preview only with a new accepted
            // stitch version.
            model.preview = progress.image
            progress.trace?.event("preview-displayed", image: progress.image,
                                  details: "accepted=\(progress.acceptedFrames) direction=\(String(describing: progress.direction))")
            model.acceptedFrames = progress.acceptedFrames
            model.direction = progress.direction
        } else {
            progress.trace?.event("preview-retained", details: "incoming=\(progress.acceptedFrames) displayed=\(scrollingModel?.acceptedFrames ?? -1)")
        }
    }

    static func dismissScrollingCapture() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { dismissScrollingCapture() }
            return
        }
        scrollingPanel?.orderOut(nil)
        scrollingPanel?.contentViewController = nil
        scrollingPreviewPanel?.orderOut(nil)
        scrollingPreviewPanel?.contentViewController = nil
        scrollingModel = nil
    }

    private static func present(_ content: AnyView,
                                dismissAfter: Double,
                                windowShadow: Bool = true) {
        let host = NSHostingController(rootView: content)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize

        let panel = ensurePanel()
        panel.hasShadow = windowShadow
        panel.contentViewController = host

        let frame = NSScreen.pointerVisibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2,
                              y: frame.maxY - size.height - 24,
                              width: size.width,
                              height: size.height),
                       display: true)
        generation += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        dismissWork?.cancel()
        let work = DispatchWorkItem { dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
    }

    private static func dismiss() {
        guard let panel else { return }
        let dismissed = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: {
            guard generation == dismissed else { return }
            panel.orderOut(nil)
            panel.contentViewController = nil
            dismissWork = nil
        })
    }

    private static func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = makePanel()
        self.panel = panel
        return panel
    }

    private static func ensureScrollingPanel() -> ScrollingCapturePanel {
        if let scrollingPanel { return scrollingPanel }
        let panel = ScrollingCapturePanel(contentRect: .zero,
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered,
                                          defer: false)
        configure(panel)
        panel.ignoresMouseEvents = false
        scrollingPanel = panel
        return panel
    }

    private static func ensureScrollingPreviewPanel() -> NSPanel {
        if let scrollingPreviewPanel { return scrollingPreviewPanel }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        configure(panel)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        scrollingPreviewPanel = panel
        return panel
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        configure(panel)
        return panel
    }

    private static func configure(_ panel: NSPanel) {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}

private struct QuickToolCountdownView: View {
    let value: Int
    let progress: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            Circle()
                .trim(from: 0.04, to: 0.04 + progress * 0.92)
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(6)
            Text("\(value)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }
}

/// A non-activating panel that can still own Return and Escape while the
/// underlying window continues receiving pointer and scrolling events.
private final class ScrollingCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class ScrollingCaptureHUDModel: ObservableObject {
    let message: String
    let screenFrame: CGRect
    let liveRect: CGRect
    let previewRect: CGRect
    @Published var height = 0
    @Published var preview: CGImage?
    @Published var currentFrame: CGImage?
    @Published var acceptedFrames = 0
    @Published var axis: ScrollingImageStitcher.Axis = .vertical
    @Published var direction: ScreenshotScrollingCapture.Direction?

    init(message: String, screenFrame: CGRect, liveRect: CGRect, previewRect: CGRect) {
        self.message = message
        self.screenFrame = screenFrame
        self.liveRect = liveRect
        self.previewRect = previewRect
    }
}

private struct ScrollingCapturePreviewView: View {
    @ObservedObject var model: ScrollingCaptureHUDModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Cut a real hole for the selected area. Showing captured frames
            // here made the foreground trail the page by one settle cycle;
            // the transparent hole lets the actual page move continuously
            // while stitching remains conservative in the background.
            scrollingMask
            previewPane
                .frame(width: model.previewRect.width, height: model.previewRect.height)
                .position(x: local(model.previewRect).midX, y: local(model.previewRect).midY)
            livePane
                .frame(width: model.liveRect.width, height: model.liveRect.height)
                .position(x: local(model.liveRect).midX, y: local(model.liveRect).midY)
        }
        .frame(width: model.screenFrame.width, height: model.screenFrame.height)
    }

    private var scrollingMask: some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(local(model.liveRect))
            context.fill(path, with: .color(.gray.opacity(0.48)),
                         style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private func local(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - model.screenFrame.minX,
               y: model.screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    private var previewPane: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .center)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
        .shadow(color: .black.opacity(0.24), radius: 6)
    }

    private var livePane: some View {
        ZStack(alignment: .top) {
            Color.clear
            captureBadge(symbol: directionSymbol, value: nil)
        }
        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
        .shadow(color: .black.opacity(0.24), radius: 6)
    }

    private var directionSymbol: String {
        switch model.direction {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case nil: return "arrow.up.and.down"
        }
    }

    private func captureBadge(symbol: String, value: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
            if let value {
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .padding(8)
    }
}

private struct ScrollingCaptureHUDView: View {
    @ObservedObject var model: ScrollingCaptureHUDModel
    let finishTitle: String
    let cancelTitle: String
    let onAxisChange: (ScrollingImageStitcher.Axis) -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ScrollCaptureIcon()
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28)
                .help(model.message)
            ForEach(ScrollingImageStitcher.Axis.allCases, id: \.self) { axis in
                Button {
                    model.axis = axis
                    onAxisChange(axis)
                } label: {
                    ScrollCaptureIcon(horizontal: axis == .horizontal)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                        .background(model.axis == axis ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(axis == .vertical ? "纵向滚动截图：只允许上下滚动" : "横向滚动截图：左右滑动，或使用鼠标滚轮")
                .accessibilityLabel(axis == .vertical ? "纵向滚动截图" : "横向滚动截图")
            }
            toolbarGlyph("scribble.variable", help: model.message)
            toolbarGlyph("pin", help: model.message)
            toolbarGlyph("arrow.counterclockwise", help: model.message)
            toolbarGlyph("ellipsis", help: model.message)
            Divider().frame(height: 20).padding(.horizontal, 2)
            Button(action: onCancel) {
                ScreenshotToolIcon(symbol: "arrow.left")
                    .frame(width: 29, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(cancelTitle)
            .keyboardShortcut(.cancelAction)
            Button(action: onFinish) {
                ScreenshotToolIcon(symbol: "checkmark")
                    .frame(width: 29, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(finishTitle)
            .keyboardShortcut(.defaultAction)
        }
        .padding(5)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }

    private func toolbarGlyph(_ symbol: String, help: String) -> some View {
        ScreenshotToolIcon(symbol: symbol)
            .frame(width: 28, height: 28)
            .help(help)
    }
}
