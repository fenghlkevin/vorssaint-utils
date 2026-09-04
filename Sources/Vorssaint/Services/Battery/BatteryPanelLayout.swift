// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics

enum BatteryPanelLayout {
    /// All coordinates are AppKit screen points, not pixels. Use the screen
    /// containing the status item, including displays with a negative origin.
    static func viewport(visibleFrame: CGRect, anchorBottom: CGFloat) -> CGSize {
        let available = max(1, min(anchorBottom, visibleFrame.maxY) - visibleFrame.minY - 24)
        return CGSize(width: min(320, max(1, visibleFrame.width - 24)),
                      height: min(820, available))
    }

    static func contentScale(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(1, max(1, viewportHeight) / max(1, contentHeight))
    }
}
