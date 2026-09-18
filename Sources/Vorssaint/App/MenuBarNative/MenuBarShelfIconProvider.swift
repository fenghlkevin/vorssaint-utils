// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Use source artwork, never wallpaper-contaminated screen crops. Application
/// artwork keeps its own colors/alpha; system symbols adapt to the panel theme.
enum MenuBarShelfIconProvider {
    static func image(bundleIdentifier: String?, systemIdentifier: Int?,
                      applicationIcon: (String) -> NSImage? = {
                          NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.icon
                      }) -> NSImage {
        if let bundleIdentifier, let original = applicationIcon(bundleIdentifier),
           let copy = original.copy() as? NSImage {
            copy.isTemplate = false
            return copy
        }
        let symbol: String
        switch systemIdentifier.flatMap(MBSystemItemIdentifier.init(rawValue:)) {
        case .battery: symbol = "battery.100percent"
        case .bluetooth: symbol = "antenna.radiowaves.left.and.right"
        case .clock: symbol = "clock"
        case .displays: symbol = "display"
        case .keyboard: symbol = "keyboard"
        case .volume: symbol = "speaker.wave.2"
        case .wifi: symbol = "wifi"
        case .screenMirroring: symbol = "rectangle.on.rectangle"
        case .primaryBento: symbol = "switch.2"
        case nil: symbol = "app.dashed"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }
}
