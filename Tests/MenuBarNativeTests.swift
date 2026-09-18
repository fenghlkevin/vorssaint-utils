// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices

@MainActor private final class TestSource: AXMenuBarSource {
    var isTrusted = true
    var reads = 0
    var records: [AXMenuBarItemRecord] = []
    func visibleMenuBarItems() throws -> [AXMenuBarItemRecord] { reads += 1; return records }
}

@MainActor private final class TestBridge: PrivateMenuBarBridging {
    var isAvailable = true
    var signatureEligible = true
    var fail = false
    var activations = 0
    var invalidations = 0
    var bundles: [String] = []
    var systemItems: [Int] = []
    func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String]) async throws {
        activations += 1
        if fail { throw MenuBarIconHidingError.nativeOperationFailed }
        bundles = allowedBundleIdentifiers
        systemItems = allowedSystemItems
    }
    func invalidate() { invalidations += 1 }
}

@main struct MenuBarNativeTests {
    @MainActor static func main() async throws {
        let source = TestSource()
        source.records = [
            .init(midX: -700, bundleIdentifier: "left", systemItemIdentifier: nil),
            .init(midX: -650, bundleIdentifier: "both", systemItemIdentifier: nil),
            .init(midX: -550, bundleIdentifier: "own", systemItemIdentifier: nil),
            .init(midX: -480, bundleIdentifier: "both", systemItemIdentifier: nil),
            .init(midX: -460, bundleIdentifier: "right", systemItemIdentifier: nil),
            .init(midX: -420, bundleIdentifier: nil, systemItemIdentifier: 2),
            .init(midX: -600, bundleIdentifier: nil, systemItemIdentifier: 0)
        ]
        let resolver = AXMenuBarVisibleItemResolver(
            markerScreenX: { -500 }, mainItemScreenX: { -450 },
            runningBundleIdentifiers: { ["own", "left", "right", "both", "noIcon"] },
            ownBundleIdentifier: { "own" }, source: source)
        let items = try resolver.itemsToKeepVisible()
        precondition(items.allowedBundleIdentifiers == ["both", "noIcon", "own", "right"])
        precondition(items.allowedSystemItemIdentifiers == [2])
        source.isTrusted = false
        do { _ = try resolver.itemsToKeepVisible(); fatalError("must reject missing AX") }
        catch { precondition(error as? MenuBarIconHidingError == .accessibilityDenied) }
        precondition(source.reads == 1)
        source.isTrusted = true
        let unsafe = AXMenuBarVisibleItemResolver(
            markerScreenX: { 600 }, mainItemScreenX: { 500 },
            ownBundleIdentifier: { "own" }, source: source)
        do { _ = try unsafe.itemsToKeepVisible(); fatalError("must reject unsafe marker") }
        catch { precondition(error as? MenuBarIconHidingError == .invalidMarkerPosition) }

        let bridge = TestBridge()
        let native = MenuBarClientCoreVisibilityApplier(bridge: bridge)
        var legacyRequests: [Bool] = []
        let legacy = LegacyMarkerVisibilityApplier { legacyRequests.append($0) }
        let coordinator = MenuBarIconHidingCoordinator(
            operatingSystemMajorVersion: { 27 }, nativeApplier: native,
            legacyApplier: legacy, visibleItemResolver: resolver)
        try await coordinator.setCollapsed(true)
        precondition(bridge.bundles == items.allowedBundleIdentifiers)
        precondition(legacyRequests.isEmpty)
        try await coordinator.setCollapsed(false)
        precondition(bridge.invalidations == 1)
        bridge.signatureEligible = false
        source.isTrusted = false
        let readsBeforeSignatureCheck = source.reads
        do { try await coordinator.setCollapsed(true); fatalError("must reject ineligible signer before AX access") }
        catch { precondition(error as? MenuBarIconHidingError == .signatureIneligible) }
        precondition(source.reads == readsBeforeSignatureCheck && bridge.activations == 1)
        bridge.signatureEligible = true
        source.isTrusted = true
        bridge.isAvailable = false
        do { try await coordinator.setCollapsed(true); fatalError("must reject unavailable bridge") }
        catch { precondition(error as? MenuBarIconHidingError == .nativeAPIUnavailable) }
        precondition(bridge.activations == 1 && legacyRequests.isEmpty)
        bridge.isAvailable = true
        bridge.fail = true
        do { try await coordinator.setCollapsed(true); fatalError("must surface activation failure") }
        catch { precondition(error as? MenuBarIconHidingError == .nativeOperationFailed) }
        precondition(legacyRequests.isEmpty)
        bridge.fail = false
        try await coordinator.setCollapsed(true)
        native.invalidateSynchronously()
        precondition(bridge.invalidations == 2)
        let old = MenuBarIconHidingCoordinator(
            operatingSystemMajorVersion: { 26 }, nativeApplier: native,
            legacyApplier: legacy, visibleItemResolver: unsafe)
        try await old.setCollapsed(true)
        try await old.setCollapsed(false)
        precondition(legacyRequests == [true, false])

        let display = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let node = AXMenuBarItemTreeNode(role: kAXWindowRole,
            frame: CGRect(x: -2560, y: 0, width: 2560, height: 24),
            bundleIdentifier: nil, systemItemIdentifier: nil, children: [
                .init(role: kAXGroupRole, frame: CGRect(x: -500, y: 0, width: 24, height: 24),
                    bundleIdentifier: nil, systemItemIdentifier: nil, children: [
                        .init(role: kAXApplicationRole, frame: nil, bundleIdentifier: "app",
                            systemItemIdentifier: nil, children: [])])])
        let records = try AXMenuBarRecordCollector.records(from: [node], preferredDisplayBounds: display)
        precondition(records == [.init(midX: -488, bundleIdentifier: "app", systemItemIdentifier: nil)])
        do {
            _ = try AXMenuBarRecordCollector.records(from: [node], preferredDisplayBounds: .null)
            fatalError("must reject unavailable display")
        } catch { precondition(error as? MenuBarIconHidingError == .invalidMarkerPosition) }
        print("PASS: native/legacy routing, allowlist, multi-display coordinates, AX denial, invalid placement, signature rejection, activation failure/retry and release")
        precondition(MenuBarRevealMode(rawValue: "unknown") == nil)
        precondition(MenuBarShelfSupport.isHidden(bundle: "left", system: nil,
            midX: -600, markerX: -500, allowed: items))
        precondition(!MenuBarShelfSupport.isHidden(bundle: "both", system: nil,
            midX: -600, markerX: -500, allowed: items))
        precondition(!MenuBarShelfSupport.isHidden(bundle: "own", system: nil,
            midX: -600, markerX: -500, allowed: items))
        precondition(!MenuBarShelfSupport.isHidden(bundle: nil, system: nil,
            midX: -600, markerX: -500, allowed: items))
        precondition(!MenuBarShelfSupport.isHidden(bundle: "left", system: nil,
            midX: .nan, markerX: -500, allowed: items))
        precondition(!MenuBarShelfSupport.isHidden(bundle: "left", system: nil,
            midX: -400, markerX: -500, allowed: items))
        precondition(MenuBarShelfSupport.isHidden(bundle: nil, system: 0,
            midX: -600, markerX: -500, allowed: items))
        let visible = CGRect(x: -2560, y: 0, width: 2560, height: 1416)
        for x in [-2550.0, -1200.0, -30.0] {
            for width in [220.0, 450.0, 5000.0] {
                let panel = MenuBarShelfSupport.panelFrame(
                    anchor: CGRect(x: x, y: 1416, width: 24, height: 24),
                    visible: visible, desiredWidth: width)
                precondition(visible.contains(panel))
                precondition(panel.height == 60)
            }
        }
        print("PASS: shelf membership, same-app protection, unknown-target safety and multi-display edge clamping")
        for shown in [false, true] {
            for pinned in [false, true] {
                for inside in [false, true] {
                    for delay in [0, 5] {
                        let expected = shown && !pinned && !inside && delay == 5
                        precondition(MenuBarShelfSupport.shouldScheduleDismiss(
                            isShown: shown, isPinned: pinned, pointerInside: inside, delay: delay) == expected)
                    }
                }
            }
        }
        print("PASS: panel dismissal policy for pin, pointer, visibility and disabled timeout")
        let artwork = NSImage(size: NSSize(width: 32, height: 32))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var transparentPixel = [0, 0, 0, 0]
        var redPixel = [255, 0, 0, 255]
        bitmap.setPixel(&transparentPixel, atX: 0, y: 0)
        bitmap.setPixel(&redPixel, atX: 1, y: 1)
        artwork.addRepresentation(bitmap)
        artwork.isTemplate = true
        let rendered = MenuBarShelfIconProvider.image(bundleIdentifier: "test", systemIdentifier: nil) { _ in artwork }
        precondition(rendered !== artwork && !rendered.isTemplate && artwork.isTemplate)
        precondition(rendered.size == artwork.size)
        let copiedBitmap = rendered.representations.first as! NSBitmapImageRep
        var pixel = [Int](repeating: 0, count: 4)
        copiedBitmap.getPixel(&pixel, atX: 0, y: 0)
        precondition(pixel == [0, 0, 0, 0])
        copiedBitmap.getPixel(&pixel, atX: 1, y: 1)
        precondition(pixel == [255, 0, 0, 255])
        for identifier in MBSystemItemIdentifier.allCases {
            precondition(MenuBarShelfIconProvider.image(bundleIdentifier: nil,
                systemIdentifier: identifier.rawValue).isTemplate)
        }
        precondition(MenuBarShelfIconProvider.image(bundleIdentifier: "missing", systemIdentifier: nil) { _ in nil }.isTemplate)
        print("PASS: original icon alpha/colors preserved, source image unmodified, adaptive system/fallback symbols")
    }
}
