// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics

/// Pure geometry and sizing rules for the menu bar icon divider.
enum MenuBarIconCollapserSupport {
    static let collapsedLength: CGFloat = 10_000
    static let allowedDelays = [0, 5, 10, 15, 30, 60]

    static func sanitizedDelay(_ seconds: Int) -> Int {
        allowedDelays.contains(seconds) ? seconds : 0
    }

    /// The divider must sit to the left of Vorssaint on the same menu bar.
    /// That keeps Vorssaint visible as the recovery control while the items
    /// farther left are pushed out of the available menu bar space.
    static func hasSafePlacement(mainFrame: CGRect?, dividerFrame: CGRect?) -> Bool {
        guard let mainFrame, let dividerFrame,
              mainFrame.width > 0, dividerFrame.width > 0,
              abs(mainFrame.midY - dividerFrame.midY) < max(mainFrame.height, dividerFrame.height)
        else { return false }
        return dividerFrame.maxX <= mainFrame.minX + 2
    }
}
