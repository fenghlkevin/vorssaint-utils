// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Allows only capture controls and axis-constrained scrolling during capture.
/// A session event tap is needed: NSEvent global monitors cannot change input
/// delivered to the underlying application.
final class ScreenshotScrollAxisController: @unchecked Sendable {
    private let lock = NSLock()
    private var selected: ScrollingImageStitcher.Axis = .vertical
    var axis: ScrollingImageStitcher.Axis {
        get { lock.withLock { selected } }
        set { lock.withLock { selected = newValue } }
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var region = CGRect.zero
    private var toolbar = CGRect.zero
    private var toolbarPress = false
    private var onFinish: (() -> Void)?
    private var onCancel: (() -> Void)?

    @MainActor func start(anchorRect: CGRect, toolbarRect: CGRect,
                          onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) -> Bool {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        region = CGRect(x: anchorRect.minX, y: height - anchorRect.maxY,
                        width: anchorRect.width, height: anchorRect.height)
        toolbar = CGRect(x: toolbarRect.minX, y: height - toolbarRect.maxY,
                         width: toolbarRect.width, height: toolbarRect.height)
        self.onFinish = onFinish
        self.onCancel = onCancel
        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
            .otherMouseDragged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<ScreenshotScrollAxisController>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = controller.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if type == .scrollWheel {
                    guard controller.region.contains(event.location) else { return nil }
                    ScreenshotScrollAxisController.constrain(event, axis: controller.axis)
                } else if type == .keyDown || type == .keyUp {
                    if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        let key = event.getIntegerValueField(.keyboardEventKeycode)
                        if key == 53 { controller.onCancel?() }
                        else if key == 36 || key == 76 { controller.onFinish?() }
                    }
                    return nil
                } else if type == .leftMouseDown {
                    controller.toolbarPress = controller.toolbar.contains(event.location)
                    if !controller.toolbarPress { return nil }
                } else if type == .leftMouseUp {
                    // AppKit must receive the matching release even if a toolbar
                    // press is cancelled by moving outside the button.
                    let allowed = controller.toolbarPress
                    controller.toolbarPress = false
                    if !allowed { return nil }
                } else if type == .leftMouseDragged {
                    if !controller.toolbarPress { return nil }
                } else if type != .mouseMoved {
                    // Do not let background windows receive drags or secondary clicks.
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    @MainActor func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        toolbarPress = false
        onFinish = nil; onCancel = nil
    }

    static func constrain(_ event: CGEvent, axis: ScrollingImageStitcher.Axis) {
        let pairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)]
        // Normal mice have only a vertical wheel. In horizontal mode redirect
        // it, while retaining native horizontal trackpad/mouse gestures.
        let vertical = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let horizontal = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let useVertical = abs(vertical) > abs(horizontal) ||
            (vertical == 0 && horizontal == 0 && abs(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) > abs(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)))
        let values = pairs.map { y, x in
            (event.getIntegerValueField(y), event.getIntegerValueField(x))
        }
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        for (index, pair) in pairs.enumerated() {
            let (y, x) = pair
            if y == .scrollWheelEventFixedPtDeltaAxis1 {
                event.setDoubleValueField(x, value: axis == .vertical ? 0 : (useVertical ? fixedY : fixedX))
                if axis == .horizontal { event.setDoubleValueField(y, value: 0) }
                continue
            }
            if axis == .vertical { event.setIntegerValueField(x, value: 0) }
            else {
                event.setIntegerValueField(x, value: useVertical ? values[index].0 : values[index].1)
                event.setIntegerValueField(y, value: 0)
            }
        }
        // Some applications reinterpret Shift+wheel after receiving deltas.
        event.flags.subtract([.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }
}
