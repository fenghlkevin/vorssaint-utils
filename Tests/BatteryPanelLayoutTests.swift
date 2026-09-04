// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
@main struct BatteryPanelLayoutTests {
    static func main() {
        let desktop = CGRect(x: 0, y: 50, width: 1920, height: 1000)
        precondition(BatteryPanelLayout.viewport(visibleFrame: desktop, anchorBottom: 1050).height == 820)
        let small = CGRect(x: 0, y: 60, width: 1280, height: 510)
        precondition(BatteryPanelLayout.viewport(visibleFrame: small, anchorBottom: 570).height == 486)
        let secondary = CGRect(x: -1440, y: -900, width: 1440, height: 850)
        precondition(BatteryPanelLayout.viewport(visibleFrame: secondary, anchorBottom: -50).height == 820)
        let above = CGRect(x: 0, y: 1000, width: 1280, height: 500)
        precondition(BatteryPanelLayout.viewport(visibleFrame: above, anchorBottom: 1500).height == 476)
        for height in stride(from: 100, through: 1800, by: 50) {
            let frame = CGRect(x: 0, y: -100, width: 1280, height: height)
            let size = BatteryPanelLayout.viewport(visibleFrame: frame, anchorBottom: frame.maxY)
            precondition(size.height <= frame.height - 24 && size.height <= 820)
            for content in [600.0, 820, 1000, 1400] {
                let scale = BatteryPanelLayout.contentScale(contentHeight: content, viewportHeight: size.height)
                precondition(scale <= 1 && content * scale <= size.height + 0.001)
            }
        }
        print("Battery panel: small, scaled and multi-display viewport tests passed")
    }
}
