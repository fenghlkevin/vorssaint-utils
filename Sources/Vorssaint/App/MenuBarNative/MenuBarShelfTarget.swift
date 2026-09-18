// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum MenuBarRevealMode: String, CaseIterable {
    case menuBar
    case shelf
}

/// No persisted AX handles or coordinates are used to deliver clicks.
struct MenuBarShelfTarget: Identifiable {
    let id: String
    let bundleIdentifier: String?
    let systemIdentifier: Int?
    let name: String
    let frame: CGRect // CoreGraphics global, top-left coordinates
}

enum MenuBarShelfSupport {
    static func shouldScheduleDismiss(isShown: Bool, isPinned: Bool,
                                      pointerInside: Bool, delay: Int) -> Bool {
        isShown && !isPinned && !pointerInside && delay > 0
    }

    static func isHidden(bundle: String?, system: Int?, midX: CGFloat,
                         markerX: CGFloat, allowed: MenuBarVisibleItems) -> Bool {
        guard midX.isFinite, markerX.isFinite, midX < markerX else { return false }
        if let bundle { return !allowed.allowedBundleIdentifiers.contains(bundle) }
        if let system { return !allowed.allowedSystemItemIdentifiers.contains(system) }
        return false // Never invent a target for an unidentified system item.
    }

    static func panelFrame(anchor: CGRect, visible: CGRect, desiredWidth: CGFloat) -> CGRect {
        let width = min(max(180, desiredWidth), max(1, visible.width - 16))
        let x = min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        return CGRect(x: x, y: min(anchor.minY - 68, visible.maxY - 60), width: width, height: 60)
    }
}
