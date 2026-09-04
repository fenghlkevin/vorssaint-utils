// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Original vector artwork: a compact battery with an inset state symbol.
/// No BatFi branding or bundled image assets are used.
enum BatteryMenuIcon {
    static func draw(percent: Int?, badge: String, monochrome: Bool = true, dynamic: Bool = true) -> NSImage {
        let tint: NSColor = badge.isEmpty ? .systemYellow
            : badge == "exclamationmark" || percent == nil ? .systemRed
            : (percent ?? 100) <= 20 ? .systemRed
            : badge == "bolt.fill" ? .systemGreen : .labelColor
        let ink = monochrome ? NSColor.black : tint
        let image = NSImage(size: NSSize(width: 30, height: 18))
        // Composite the cutout offscreen, never into the menu bar itself.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 90, pixelsHigh: 54,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = NSAffineTransform(); scale.scale(by: 3); scale.concat()
            ink.withAlphaComponent(0.65).setFill()
            let shell = NSBezierPath(roundedRect: NSRect(x: 1, y: 2.5, width: 25, height: 13), xRadius: 3, yRadius: 3)
            ink.withAlphaComponent(0.65).setStroke()
            shell.lineWidth = 1
            shell.stroke()
            NSBezierPath(roundedRect: NSRect(x: 27, y: 6.5, width: 2, height: 5), xRadius: 1, yRadius: 1).fill()
            if let percent {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: NSRect(x: 3, y: 4.5, width: 21, height: 9), xRadius: 1.5, yRadius: 1.5).addClip()
                ink.setFill()
                NSRect(x: 3, y: 4.5, width: 21 * CGFloat(min(100, max(0, percent))) / 100, height: 9).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if dynamic || percent == nil {
                let name = percent == nil ? "questionmark" : badge
                let rect = NSRect(x: 9, y: 3.5, width: 10, height: 11)
                // Transparent clearance keeps the mark legible on both filled
                // and empty portions, in light/dark and selected menu states.
                let weight: NSFont.Weight = name == "arrow.down" ? .black : .medium
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: weight)
                    .applying(.init(paletteColors: [ink]))
                let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                if name == "arrow.down.square.fill" {
                    // White rounded tile with a black outline and a broad down
                    // arrow, kept legible at the 18-point menu-bar size.
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    NSBezierPath(roundedRect: NSRect(x: 9.5, y: 4, width: 9, height: 10),
                                 xRadius: 2, yRadius: 2).fill()
                    NSGraphicsContext.restoreGraphicsState()
                    ink.setStroke()
                    let tile = NSBezierPath(roundedRect: NSRect(x: 9.5, y: 4, width: 9, height: 10),
                                            xRadius: 2, yRadius: 2)
                    tile.lineWidth = 0.9; tile.stroke()
                    ink.setFill()
                    NSRect(x: 12.85, y: 8, width: 2.3, height: 3.3).fill()
                    let arrow = NSBezierPath()
                    arrow.move(to: NSPoint(x: 11, y: 8.3))
                    arrow.line(to: NSPoint(x: 17, y: 8.3))
                    arrow.line(to: NSPoint(x: 14, y: 5.1))
                    arrow.close(); arrow.fill()
                } else if name == "arrow.down" {
                    // Cut out the broad outer silhouette, then draw the inner
                    // mark using the normal menu-bar foreground colour. The
                    // transparent border remains legible in light, dark and
                    // selected menu-bar states without forcing a yellow tint.
                    func arrowPath(stemX: CGFloat, stemWidth: CGFloat,
                                   shoulderLeft: CGFloat, shoulderRight: CGFloat,
                                   shoulderY: CGFloat, tipY: CGFloat) -> NSBezierPath {
                        let path = NSBezierPath()
                        path.appendRect(NSRect(x: stemX, y: shoulderY,
                                               width: stemWidth, height: 4.1))
                        path.move(to: NSPoint(x: shoulderLeft, y: shoulderY + 0.4))
                        path.line(to: NSPoint(x: shoulderRight, y: shoulderY + 0.4))
                        path.line(to: NSPoint(x: 14, y: tipY))
                        path.close()
                        return path
                    }
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    arrowPath(stemX: 11.7, stemWidth: 4.6,
                              shoulderLeft: 8.7, shoulderRight: 19.3,
                              shoulderY: 8.2, tipY: 3.8).fill()
                    NSGraphicsContext.restoreGraphicsState()
                    ink.setFill()
                    arrowPath(stemX: 12.7, stemWidth: 2.6,
                              shoulderLeft: 10.1, shoulderRight: 17.9,
                              shoulderY: 8.7, tipY: 5.1).fill()
                } else if name == "arrow.down.to.line.compact" {
                    symbol?.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
                } else {
                    for offset in [NSPoint(x: -0.8, y: 0), NSPoint(x: 0.8, y: 0),
                                   NSPoint(x: 0, y: -0.8), NSPoint(x: 0, y: 0.8)] {
                        symbol?.draw(in: rect.offsetBy(dx: offset.x, dy: offset.y), from: .zero,
                                     operation: .destinationOut, fraction: 1)
                    }
                    symbol?.draw(in: rect)
                }
            }
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = image.size
        image.addRepresentation(bitmap)
        image.isTemplate = monochrome
        return image
    }
}
