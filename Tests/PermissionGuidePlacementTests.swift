import Foundation
import CoreGraphics

@main
enum PermissionGuidePlacementTests {
    static func main() {
        let size = CGSize(width: 390, height: 370)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let settings = CGRect(x: 250, y: 100, width: 600, height: 740)
        let right = PermissionGuidePlacement.frame(size: size, settings: settings,
                                                    visible: screen, pointer: .zero)
        precondition(right.minX == settings.maxX + 14 && right.maxY == settings.maxY)
        let shifted = settings.offsetBy(dx: 500, dy: 0)
        let left = PermissionGuidePlacement.frame(size: size, settings: shifted,
                                                   visible: screen, pointer: .zero)
        precondition(left.maxX == shifted.minX - 14)
        let narrow = CGRect(x: 0, y: 0, width: 920, height: 600)
        let overlapping = PermissionGuidePlacement.frame(size: size, settings: narrow,
                                                          visible: narrow, pointer: .zero)
        precondition(narrow.contains(overlapping) && overlapping.minX == 16)
        let secondScreen = screen.offsetBy(dx: -1440, dy: 900)
        let secondary = PermissionGuidePlacement.frame(size: size,
            settings: settings.offsetBy(dx: -1440, dy: 900), visible: secondScreen, pointer: .zero)
        precondition(secondScreen.contains(secondary))
        let fallback = PermissionGuidePlacement.frame(size: size, settings: nil,
            visible: secondScreen, pointer: CGPoint(x: -4, y: 1798))
        precondition(secondScreen.contains(fallback))
        print("Permission guide placement: 5 cases passed")
    }
}
