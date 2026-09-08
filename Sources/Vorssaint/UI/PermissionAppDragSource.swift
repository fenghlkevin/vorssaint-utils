// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Native file dragging: the payload is this app's bundle URL, not an image
/// or a promised file. No copy or permission change is performed by the app.
struct PermissionAppDragSource: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PermissionAppDragView {
        PermissionAppDragView(url: url)
    }

    func updateNSView(_ nsView: PermissionAppDragView, context: Context) {
        nsView.url = url
    }
}

final class PermissionAppDragView: NSView, NSDraggingSource {
    var url: URL
    private var origin: NSPoint?
    private weak var sourceWindow: NSWindow?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        origin = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) { origin = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let origin,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4,
              url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path) else { return }
        self.origin = nil
        sourceWindow = window
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                              contents: NSWorkspace.shared.icon(forFile: url.path))
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // Let the destination receive drops even if the card overlaps its list.
        sourceWindow?.ignoresMouseEvents = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        sourceWindow?.ignoresMouseEvents = false
        sourceWindow = nil
        origin = nil
        // A completed drop is not evidence of permission being granted.
    }
}
