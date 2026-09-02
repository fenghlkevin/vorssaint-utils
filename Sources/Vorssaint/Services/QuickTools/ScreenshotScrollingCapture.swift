// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics

/// Settled-frame scrolling capture. Wheel events wake the sampler; pixels,
/// rather than event deltas, decide what was actually added to the page.
enum ScreenshotScrollingCapture {
    enum Direction: Sendable { case up, down, left, right }
    struct Progress: @unchecked Sendable {
        let image: CGImage
        let currentFrame: CGImage
        let pixelLength: Int
        let acceptedFrames: Int
        let direction: Direction?
        var trace: ScreenshotCaptureTrace?
    }
    final class FinishSignal: @unchecked Sendable {
        private let lock = NSLock(); private var requested = false
        func request() { lock.withLock { requested = true } }
        var isRequested: Bool { lock.withLock { requested } }
    }
    enum Result {
        case success(ScreenshotSelectionController.Capture)
        case partial(ScreenshotSelectionController.Capture)
        case limited(ScreenshotSelectionController.Capture)
        case cancelled, failed
    }

    private final class Activity: @unchecked Sendable {
        struct State { let serial: Int; let time: TimeInterval }
        private let lock = NSLock(); private var serial = 0; private var time: TimeInterval = 0
        func record() { lock.withLock { serial += 1; time = ProcessInfo.processInfo.systemUptime } }
        var state: State { lock.withLock { State(serial: serial, time: time) } }
    }
    private struct Monitors: @unchecked Sendable { let local: Any?; let global: Any? }
    static func capture(region: RecorderSupport.Region, includePointer: Bool,
                        hideVorssaintWindows: Bool, protectedWindowIDs: Set<CGWindowID>,
                        finishSignal: FinishSignal,
                        trace: ScreenshotCaptureTrace,
                        axisController: ScreenshotScrollAxisController,
                        onProgress: @escaping @MainActor (Progress) -> Void) async -> Result {
        trace.event("scroll-start", details: "display=\(region.displayID) pixelRect=\(region.pixelRect) scale=\(region.scale)")
        func report(_ progress: Progress) async {
            var progress = progress
            progress.trace = trace
            await onProgress(progress)
        }
        func complete(_ image: CGImage, _ kind: Completion) -> Result {
            completed(image, region, kind, trace: trace)
        }
        let activity = Activity(), monitors = await installMonitors(activity)
        defer { Task { @MainActor in removeMonitors(monitors) } }
        do {
            guard let first = await frame(region, includePointer, hideVorssaintWindows, protectedWindowIDs),
                  var stitcher = ScrollingImageStitcher(image: first, maximumPixels: ScreenshotSupport.scrollingCaptureMaximumPixels) else {
                trace.event("failed", details: "initial capture or fingerprint unavailable")
                return .failed
            }
            var output = first, accepted = 1, seen = activity.state.serial, pending = false
            trace.event("raw-frame", image: first, details: "initial accepted=1")
            var finishAt: TimeInterval?
            let started = ProcessInfo.processInfo.systemUptime
            var lastRefresh = started
            await report(Progress(image: output, currentFrame: first,
                                      pixelLength: output.height,
                                      acceptedFrames: accepted, direction: nil))
            while true {
                try Task.checkCancellation()
                let now = ProcessInfo.processInfo.systemUptime, state = activity.state
                if state.serial != seen {
                    trace.event("scroll-activity", details: "serial=\(state.serial) previous=\(seen) eventTime=\(state.time)")
                    seen = state.serial; pending = true
                }
                if finishSignal.isRequested, finishAt == nil { finishAt = now }
                if let finishAt, !pending || now - finishAt > 0.65 {
                    return complete(output, accepted > 1 ? .success : .partial)
                }
                if now - started >= ScreenshotSupport.scrollingCaptureMaximumDuration
                    || accepted >= ScreenshotSupport.scrollingCaptureMaximumFrames {
                    return complete(output, .limited)
                }
                // Refresh throughout momentum scrolling. Waiting for the last
                // wheel event made the preview freeze and then jump after the
                // page had already moved.
                guard pending, now - lastRefresh >= 0.10 else {
                    try await Task.sleep(nanoseconds: 28_000_000); continue
                }
                guard let candidate = await frame(region, includePointer,
                                                  hideVorssaintWindows, protectedWindowIDs) else {
                    trace.event("failed", details: "sample capture or fingerprint unavailable")
                    return .failed
                }
                lastRefresh = ProcessInfo.processInfo.systemUptime
                let axis = axisController.axis
                trace.event("raw-frame", image: candidate, details: "serial=\(seen) accepted=\(accepted) axis=\(axis.rawValue)")
                let latest = activity.state
                pending = latest.serial != seen
                seen = latest.serial
                guard let update = stitcher.ingest(candidate, axis: axis) else {
                    if stitcher.limitReached { return complete(output, .limited) }
                    trace.event("match-rejected", details: "accepted=\(accepted); stationary, ambiguous or insufficient overlap; retained previous composite")
                    await report(Progress(image: output, currentFrame: candidate,
                                          pixelLength: max(output.width, output.height),
                                          acceptedFrames: accepted, direction: nil))
                    continue
                }
                let direction: Direction = update.dx != 0
                    ? (update.dx > 0 ? .right : .left)
                    : (update.dy > 0 ? .down : .up)
                output = update.image
                if update.grew { accepted += 1 }
                trace.event(update.grew ? "stitched-frame" : "revisited-frame", image: output,
                            details: "accepted=\(accepted) dx=\(update.dx) dy=\(update.dy) score=\(update.score) direction=\(direction)")
                await report(Progress(image: output, currentFrame: candidate,
                                          pixelLength: max(output.width, output.height),
                                          acceptedFrames: accepted,
                                          direction: direction))
            }
        } catch is CancellationError { trace.event("cancelled"); return .cancelled }
        catch { trace.event("failed", details: String(describing: error)); return .failed }
    }

    private enum Completion { case success, partial, limited }
    private static func completed(_ image: CGImage, _ region: RecorderSupport.Region,
                                  _ kind: Completion, trace: ScreenshotCaptureTrace) -> Result {
        trace.event("scroll-completed", image: image, details: "result=\(kind) scale=\(region.scale)")
        var capture = ScreenshotSelectionController.Capture(image: image, scale: region.scale,
                                                             anchorRect: region.anchorRect)
        capture.trace = trace
        switch kind { case .success: return .success(capture); case .partial: return .partial(capture)
        case .limited: return .limited(capture) }
    }

    private static func frame(_ region: RecorderSupport.Region, _ pointer: Bool,
                              _ hidden: Bool, _ protected: Set<CGWindowID>) async -> CGImage? {
        await ScreenshotCaptureEngine.captureDisplayRegion(displayID: region.displayID,
            pixelRect: region.pixelRect, includePointer: pointer,
            hideVorssaintWindows: hidden, protectedWindowIDs: protected)
    }
    @MainActor private static func installMonitors(_ activity: Activity) -> Monitors {
        func record(_ event: NSEvent) {
            if abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 0.001 { activity.record() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { record($0); return $0 }
        return Monitors(local: local,
            global: NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: record))
    }
    @MainActor private static func removeMonitors(_ monitors: Monitors) {
        if let local = monitors.local { NSEvent.removeMonitor(local) }
        if let global = monitors.global { NSEvent.removeMonitor(global) }
    }
}
