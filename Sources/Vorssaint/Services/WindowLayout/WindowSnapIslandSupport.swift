// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import CoreGraphics

/// AppKit coordinates throughout. Drawing and pointer hit testing share these cells.
struct WindowSnapIslandLayout {
    struct Cell {
        let action: WindowLayoutAction
        let frame: CGRect
    }
    static let groups: [[WindowLayoutAction]] = [
        [.maximize], [.leftHalf, .rightHalf], [.topHalf, .bottomHalf],
        [.leftThird, .centerThird, .rightThird],
        [.leftTwoThirds, .rightThird], [.leftThird, .rightTwoThirds],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
    ]
    let compactFrame: CGRect
    let expandedFrame: CGRect
    let cells: [Cell]

    init(visibleFrame: CGRect) {
        let width = min(600, max(1, visibleFrame.width - 24))
        let top = visibleFrame.maxY - min(60, visibleFrame.height * 0.12)
        compactFrame = CGRect(x: visibleFrame.midX - min(148, width) / 2,
                              y: top - 32, width: min(148, width), height: 32)
        expandedFrame = CGRect(x: visibleFrame.midX - width / 2, y: top - 108,
                               width: width, height: 108)
        let padding: CGFloat = 14
        let spacing: CGFloat = 10
        let tileWidth = max(1, (width - padding * 2 - spacing * 6) / 7)
        let panelFrame = expandedFrame
        cells = Self.groups.enumerated().flatMap { index, actions in
            let tile = CGRect(x: panelFrame.minX + padding + CGFloat(index) * (tileWidth + spacing),
                              y: panelFrame.minY + 16, width: tileWidth, height: 46)
            return actions.map { action in
                Cell(action: action,
                     frame: WindowLayoutGeometry.rect(for: action, current: tile,
                                                       visibleFrame: tile, windowGap: 3))
            }
        }
    }

    func shouldExpand(at point: CGPoint, expanded: Bool) -> Bool {
        (expanded ? expandedFrame.insetBy(dx: -24, dy: -24)
                  : compactFrame.insetBy(dx: -36, dy: -30)).contains(point)
    }

    func action(at point: CGPoint) -> WindowLayoutAction? {
        cells.first(where: { $0.frame.contains(point) })?.action
    }
}
