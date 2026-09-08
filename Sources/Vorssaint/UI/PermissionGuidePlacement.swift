// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CoreGraphics

enum PermissionGuidePlacement {
    /// Prefer the settings window's right edge, then its left. On narrow
    /// screens overlap the left sidebar rather than the permission switches.
    static func frame(size: CGSize, settings: CGRect?, visible: CGRect,
                      pointer: CGPoint) -> CGRect {
        let margin: CGFloat = 16
        let gap: CGFloat = 14
        let x: CGFloat
        let y: CGFloat
        if let settings {
            if settings.maxX + gap + size.width <= visible.maxX - margin {
                x = settings.maxX + gap
            } else if settings.minX - gap - size.width >= visible.minX + margin {
                x = settings.minX - gap - size.width
            } else {
                x = visible.minX + margin
            }
            y = settings.maxY - size.height
        } else {
            x = pointer.x + gap
            y = pointer.y - size.height / 2
        }
        return CGRect(x: min(max(x, visible.minX + margin), max(visible.minX + margin, visible.maxX - size.width - margin)),
                      y: min(max(y, visible.minY + margin), max(visible.minY + margin, visible.maxY - size.height - margin)),
                      width: size.width, height: size.height)
    }
}
