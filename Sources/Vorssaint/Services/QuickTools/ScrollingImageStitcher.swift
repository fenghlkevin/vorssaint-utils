// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Tracks the viewport in document coordinates. The accumulated canvas never
/// shrinks, and revisiting captured content does not append it a second time.
struct ScrollingImageStitcher {
    enum Axis: String, CaseIterable { case vertical, horizontal }
    struct Update {
        let image: CGImage
        let dx: Int
        let dy: Int
        let score: Double
        let grew: Bool
    }
    private struct Pixels {
        let width: Int, height: Int
        let values: [UInt8]
    }
    private struct Match { let dx: Int, dy: Int; let score: Double }
    private var reference: Pixels
    private var coarse: Pixels
    private var viewport = CGPoint.zero
    private var canvas: CGRect
    private(set) var image: CGImage
    private(set) var limitReached = false
    private let maximumPixels: Int

    init?(image: CGImage, maximumPixels: Int) {
        guard let reference = Self.pixels(image),
              let coarse = Self.pixels(image, small: true) else { return nil }
        self.image = image
        self.reference = reference
        self.coarse = coarse
        self.maximumPixels = maximumPixels
        canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    mutating func ingest(_ candidate: CGImage, axis: Axis? = nil) -> Update? {
        guard candidate.width == reference.width, candidate.height == reference.height,
              let small = Self.pixels(candidate, small: true),
              let approximate = Self.match(coarse, small, axis: axis),
              let full = Self.pixels(candidate),
              let match = Self.refine(reference, full, approximate: approximate,
                                      coarseSize: CGSize(width: small.width, height: small.height))
        else { return nil }
        let nextViewport = CGPoint(x: viewport.x + CGFloat(match.dx), y: viewport.y + CGFloat(match.dy))
        let candidateRect = CGRect(origin: nextViewport,
                                   size: CGSize(width: candidate.width, height: candidate.height))
        let union = canvas.union(candidateRect).integral
        let count = Int(union.width).multipliedReportingOverflow(by: Int(union.height))
        guard !count.overflow, count.partialValue <= maximumPixels else {
            limitReached = true
            return nil
        }
        let grew = union != canvas
        if grew {
            guard let context = CGContext(data: nil, width: Int(union.width), height: Int(union.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // Convert our top-left document coordinates to Quartz bottom-left.
            func destination(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX - union.minX, y: union.maxY - rect.maxY,
                       width: rect.width, height: rect.height)
            }
            context.interpolationQuality = .none
            let oldRect = destination(canvas)
            context.draw(image, in: oldRect)
            // Only fill newly captured territory; keep established overlaps
            // unchanged, including when scrolling back or changing axes.
            context.addRect(CGRect(origin: .zero, size: union.size))
            context.addRect(oldRect)
            context.clip(using: .evenOdd)
            context.draw(candidate, in: destination(candidateRect))
            guard let result = context.makeImage() else { return nil }
            image = result
        }
        viewport = nextViewport; canvas = union
        reference = full; coarse = small
        return Update(image: image, dx: match.dx, dy: match.dy, score: match.score, grew: grew)
    }

    private static func pixels(_ image: CGImage, small: Bool = false) -> Pixels? {
        let width = small ? min(192, image.width) : image.width
        let height = small ? min(256, image.height) : image.height
        var values = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &values, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = small ? .medium : .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(width: width, height: height, values: values)
    }

    /// A positive delta means the new viewport is further right/down in the
    /// document: new[x,y] matches old[x+dx,y+dy]. Blank background must not
    /// dominate the score. Always include zero motion as the baseline.
    private static func score(_ old: Pixels, _ new: Pixels, dx: Int, dy: Int,
                              step: Int, horizontal: Bool? = nil) -> Double {
        let marginX = max(1, old.width / 20), marginY = max(1, old.height / 20)
        let x0 = max(marginX, marginX - dx), x1 = min(old.width - marginX, old.width - marginX - dx)
        let y0 = max(marginY, marginY - dy), y1 = min(old.height - marginY, old.height - marginY - dy)
        guard x1 - x0 >= old.width / 5, y1 - y0 >= old.height / 5 else { return .infinity }
        var sum = 0, count = 0, samples = 0
        var texturedBands = [Int](repeating: 0, count: 8)
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) {
                let a = Int(old.values[(y + dy) * old.width + x + dx])
                let b = Int(new.values[y * new.width + x])
                samples += 1
                // White webpage space and uniform dark backgrounds carry no
                // positional information. Require local texture in either frame.
                let edgeA = abs(a - Int(old.values[(y + dy) * old.width + x + dx + 1]))
                let edgeB = abs(b - Int(new.values[y * new.width + x + 1]))
                let verticalA = abs(a - Int(old.values[(y + dy + 1) * old.width + x + dx]))
                let verticalB = abs(b - Int(new.values[(y + 1) * new.width + x]))
                // A horizontal line says nothing about horizontal motion (and
                // vice versa). Previously the highlighted editor row dominated
                // horizontal matching and made arbitrary offsets look perfect.
                let texture = horizontal == true ? max(edgeA, edgeB)
                    : horizontal == false ? max(verticalA, verticalB)
                    : max(edgeA, edgeB, verticalA, verticalB)
                if texture >= 6 {
                    sum += abs(a - b); count += 1
                    texturedBands[min(7, (y - y0) * 8 / max(1, y1 - y0))] += 1
                }
            }
        }
        guard count >= max(12, samples / 100) else { return .infinity }
        // A lone repeated text row / caret near an edge cannot anchor a
        // horizontal document. Require corroboration in separate row bands.
        if horizontal == true, texturedBands.filter({ $0 >= 6 }).count < 2 {
            return .infinity
        }
        return Double(sum) / Double(count)
    }

    private static func match(_ old: Pixels, _ new: Pixels, axis: Axis?) -> Match? {
        let horizontal = axis.map { $0 == .horizontal }
        let zero = score(old, new, dx: 0, dy: 0, step: 4, horizontal: horizontal)
        guard zero > 1 else { return nil }
        // Infinity means insufficient evidence, not a very bad alignment.
        // It must not make any finite candidate automatically acceptable.
        if horizontal == true, !zero.isFinite { return nil }
        var best = Match(dx: 0, dy: 0, score: zero)
        var candidates: [Match] = []
        func test(_ dx: Int, _ dy: Int) {
            let value = score(old, new, dx: dx, dy: dy, step: 4, horizontal: dx != 0)
            candidates.append(Match(dx: dx, dy: dy, score: value))
            if value < best.score { best = Match(dx: dx, dy: dy, score: value) }
        }
        if axis != .horizontal {
            for dy in 1...max(1, old.height * 3 / 4) { test(0, dy); test(0, -dy) }
        }
        if axis != .vertical {
            for dx in 1...max(1, old.width * 3 / 4) { test(dx, 0); test(-dx, 0) }
        }
        guard best.dx != 0 || best.dy != 0, best.score < 30,
              best.score < zero * 0.65 else { return nil }
        // Repeated text can have multiple equally plausible alignments.
        // Never expand the canvas using an arbitrary periodic match.
        let competitor = candidates.filter {
            abs($0.dx - best.dx) + abs($0.dy - best.dy) > 3
        }.map(\.score).min() ?? .infinity
        guard competitor > max(best.score * 1.2, best.score + 1.0) else { return nil }
        if best.dx != 0,
           !score(old, new, dx: 0, dy: 0, step: 4, horizontal: true).isFinite { return nil }
        return best
    }

    private static func refine(_ old: Pixels, _ new: Pixels, approximate: Match,
                               coarseSize: CGSize) -> Match? {
        let horizontal = approximate.dx != 0
        let ratio = horizontal ? Double(old.width) / coarseSize.width : Double(old.height) / coarseSize.height
        let center = Int((Double(horizontal ? approximate.dx : approximate.dy) * ratio).rounded())
        let radius = max(2, Int(ceil(ratio)) + 1)
        let step = max(1, min(old.width, old.height) / 180)
        let zero = score(old, new, dx: 0, dy: 0, step: step, horizontal: horizontal)
        if horizontal, !zero.isFinite { return nil }
        var best = Match(dx: 0, dy: 0, score: zero)
        for delta in (center - radius)...(center + radius) {
            let dx = horizontal ? delta : 0, dy = horizontal ? 0 : delta
            let value = score(old, new, dx: dx, dy: dy, step: step, horizontal: horizontal)
            if value < best.score { best = Match(dx: dx, dy: dy, score: value) }
        }
        guard best.dx != 0 || best.dy != 0, best.score < 22,
              best.score < zero * 0.65 else { return nil }
        return best
    }
}
