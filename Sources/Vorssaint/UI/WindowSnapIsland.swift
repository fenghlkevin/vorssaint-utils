// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore

/// Never becomes key or takes mouse events: the original app keeps its native drag.
final class WindowSnapIsland {
    private var panel: NSPanel?
    private var displayFrame: CGRect?
    private var cachedLayout: WindowSnapIslandLayout?
    private var visibilityGeneration = 0
    private var hiding = false
    private var expanded = false
    var isVisible: Bool { panel?.isVisible == true && !hiding }

    func update(at point: CGPoint, screen: NSScreen) -> (ownsPointer: Bool, action: WindowLayoutAction?) {
        let screenChanged = displayFrame != screen.visibleFrame
        visibilityGeneration += 1
        let wasHiding = hiding
        hiding = false
        let wasExpanded = expanded
        if screenChanged {
            expanded = false
            displayFrame = screen.visibleFrame
            cachedLayout = WindowSnapIslandLayout(visibleFrame: screen.visibleFrame)
        }
        guard let layout = cachedLayout else { return (false, nil) }
        expanded = layout.shouldExpand(at: point, expanded: expanded)
        let action = expanded ? layout.action(at: point) : nil
        let frame = layout.expandedFrame
        let window: NSPanel
        if let panel { window = panel } else {
            window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            window.animationBehavior = .none
            window.contentView = WindowSnapIslandCanvas()
            panel = window
        }
        let appearing = !window.isVisible || wasHiding
        if screenChanged || !window.isVisible {
            window.setFrame(frame, display: false)
        }
        if let canvas = window.contentView as? WindowSnapIslandCanvas {
            canvas.update(layout: layout, expanded: expanded, action: action, point: point,
                          transition: wasExpanded != expanded,
                          animate: !appearing && !screenChanged)
        }
        if appearing {
            if !window.isVisible {
                window.alphaValue = 0
                window.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                window.animator().alphaValue = 1
            }
        }
        return (expanded && layout.expandedFrame.insetBy(dx: -24, dy: -24).contains(point), action)
    }

    func hide() {
        guard let panel, panel.isVisible, !hiding else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        hiding = true
        expanded = false
        displayFrame = nil
        cachedLayout = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard let self, self.visibilityGeneration == generation else { return }
            panel?.orderOut(nil)
            self.hiding = false
        }
    }
}

/// A fixed-size window and cached view contents let Core Animation compose
/// the transition without resizing a WindowServer surface on every frame.
private final class WindowSnapIslandCanvas: NSView {
    private let compactView = WindowSnapIslandView()
    private let expandedView = WindowSnapIslandView()
    private let compactLayer = CALayer()
    private let expandedLayer = CALayer()
    private var configuredFrame: CGRect?
    private var selectedCell: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // These are owned sublayers, not AppKit-managed NSView backing layers.
        // AppKit must never reset their anchor/position during view layout.
        layer?.addSublayer(compactLayer)
        layer?.addSublayer(expandedLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(layout: WindowSnapIslandLayout, expanded: Bool,
                action: WindowLayoutAction?, point: CGPoint, transition: Bool, animate: Bool) {
        let reconfigure = configuredFrame != layout.expandedFrame
        let cell = expanded ? layout.cells.first(where: { $0.frame.contains(point) })?.frame : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reconfigure {
            configuredFrame = layout.expandedFrame
            compactView.frame = layout.compactFrame.offsetBy(dx: -layout.expandedFrame.minX,
                                                              dy: -layout.expandedFrame.minY)
            expandedView.frame = CGRect(origin: .zero, size: layout.expandedFrame.size)
            for view in [compactView, expandedView] { view.layout = layout }
            compactView.expanded = false
            expandedView.expanded = true
            compactLayer.frame = compactView.frame
            expandedLayer.bounds = CGRect(origin: .zero, size: layout.expandedFrame.size)
            expandedLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
            expandedLayer.position = CGPoint(x: layout.expandedFrame.width / 2,
                                             y: layout.expandedFrame.height)
            render(compactView, into: compactLayer)
        }
        if reconfigure || selectedCell != cell {
            selectedCell = cell
            expandedView.selected = action
            expandedView.pointer = point
            render(expandedView, into: expandedLayer)
        }
        CATransaction.commit()
        guard transition || reconfigure || !animate else { return }
        let small = CATransform3DMakeScale(layout.compactFrame.width / layout.expandedFrame.width,
                                         layout.compactFrame.height / layout.expandedFrame.height, 1)
        let duration = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.20 : 0
        animateLayer(expandedLayer, key: "transform", value: NSValue(caTransform3D: expanded ? CATransform3DIdentity : small),
                     duration: duration)
        animateLayer(expandedLayer, key: "opacity", value: Float(expanded ? 1 : 0), duration: duration)
        animateLayer(compactLayer, key: "opacity", value: Float(expanded ? 0 : 1), duration: duration)
    }

    private func render(_ view: WindowSnapIslandView, into target: CALayer) {
        let scale = window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        target.contentsScale = scale
        target.contents = bitmap.cgImage
    }

    private func animateLayer(_ layer: CALayer?, key: String, value: Any, duration: Double) {
        guard let layer else { return }
        let start = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        layer.removeAnimation(forKey: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = start
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: key)
        }
    }
}

private final class WindowSnapIslandView: NSView {
    var layout: WindowSnapIslandLayout?
    var expanded = false
    var selected: WindowLayoutAction?
    var pointer = CGPoint.zero

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 15.5, yRadius: 15.5).stroke()
        let copy = WindowSnapCopy(language: L10n.shared.language)
        let label: String
        if expanded {
            label = selected.map { $0.title(FeatureStrings.windowLayout(L10n.shared.language)) }
                ?? copy.choose("拖入格子，松手分屏 · Esc 取消", "Drag into a cell and release · Esc to cancel")
        } else {
            label = copy.choose("拖到这里分屏", "Drag here to arrange")
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: expanded ? 12 : 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                             y: expanded ? bounds.height * 78 / 108 : (bounds.height - size.height) / 2),
                                withAttributes: attributes)
        guard expanded else { return }
        for cell in layout.cells {
            let local = cell.frame.offsetBy(dx: -layout.expandedFrame.minX, dy: -layout.expandedFrame.minY)
            let sx = bounds.width / layout.expandedFrame.width
            let sy = bounds.height / layout.expandedFrame.height
            let rect = CGRect(x: local.minX * sx, y: local.minY * sy,
                              width: local.width * sx, height: local.height * sy)
            (cell.frame.contains(pointer) ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.13)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }
}
