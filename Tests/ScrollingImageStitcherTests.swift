// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct ScrollingImageStitcherTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ScrollingImageStitcherTests", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func document() -> CGImage {
        let c = CGContext(data: nil, width: 900, height: 1400, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 900, height: 1400))
        var seed: UInt64 = 91823
        for y in stride(from: 8, to: 1400, by: 13) {
            for x in stride(from: 8, to: 900, by: 17) {
                seed = seed &* 6364136223846793005 &+ 1
                c.setFillColor(CGColor(gray: CGFloat((seed >> 32) % 180) / 255, alpha: 1))
                c.fill(CGRect(x: x, y: y, width: 4 + Int(seed % 9), height: 3 + Int((seed >> 16) % 7)))
            }
        }
        return c.makeImage()!
    }
    static func bytes(_ image: CGImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let c = CGContext(data: &result, width: image.width, height: image.height, bitsPerComponent: 8,
                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return result
    }
    static func main() throws {
        let source = document()
        func frame(_ x: Int, _ y: Int) -> CGImage {
            source.cropping(to: CGRect(x: x, y: y, width: 400, height: 500))!
        }
        var engine = ScrollingImageStitcher(image: frame(100, 300), maximumPixels: 10_000_000)!
        var verticalOnly = engine
        try check(verticalOnly.ingest(frame(220, 300), axis: .vertical) == nil,
                  "vertical mode accepted horizontal displacement")
        var horizontalOnly = engine
        try check(horizontalOnly.ingest(frame(100, 390), axis: .horizontal) == nil,
                  "horizontal mode accepted vertical displacement")
        try check(horizontalOnly.ingest(frame(220, 300), axis: .horizontal)?.dx == 120,
                  "horizontal mode failed rightward capture")
        try check(horizontalOnly.ingest(frame(30, 300), axis: .horizontal)?.dx == -190,
                  "horizontal mode failed leftward capture")
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 32, wheel2: 15, wheel3: 0)!
        ScreenshotScrollAxisController.constrain(wheel, axis: .vertical)
        try check(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 32 &&
                  wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0, "vertical input leak")
        ScreenshotScrollAxisController.constrain(wheel, axis: .horizontal)
        try check(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0 &&
                  wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 32, "mouse wheel horizontal redirect")
        let trackpad = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 2, wheel2: -25, wheel3: 0)!
        trackpad.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -1.25)
        ScreenshotScrollAxisController.constrain(trackpad, axis: .horizontal)
        try check(trackpad.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0 &&
                  trackpad.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -25 &&
                  trackpad.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == -1.25,
                  "horizontal trackpad delta/fraction was not preserved")
        try check(engine.ingest(frame(100, 300)) == nil, "stationary frame must not grow")
        for y in [301, 390, 590, 490, 300, 190] {
            let result = engine.ingest(frame(100, y))
            print("synthetic y=\(y) delta=\(result?.dy ?? 0) size=\(engine.image.width)x\(engine.image.height)")
        }
        try check(engine.image.width == 400 && engine.image.height == 900, "vertical reversal extent incorrect")
        let expected = source.cropping(to: CGRect(x: 100, y: 190, width: 400, height: 900))!
        try check(bytes(engine.image) == bytes(expected), "vertical stitch pixel content/order incorrect")
        let horizontal = engine.ingest(frame(220, 190))
        try check(horizontal?.dx == 120 && horizontal?.dy == 0, "horizontal switch displacement incorrect")
        try check(engine.image.width == 520 && engine.image.height == 900, "axis switch shrank canvas")
        let preserved = engine.image.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 900))!
        try check(bytes(preserved) == bytes(expected), "axis switch changed existing pixels")
        let before = engine.image
        let revisit = engine.ingest(frame(100, 190))
        try check(revisit?.grew == false && bytes(engine.image) == bytes(before), "revisit duplicated or changed captured content")
        _ = engine.ingest(frame(30, 190))
        try check(engine.image.width == 590 && engine.image.height == 900, "leftward extension failed")
        var capped = ScrollingImageStitcher(image: frame(100, 300), maximumPixels: 200_000)!
        try check(capped.ingest(frame(100, 390)) == nil && capped.limitReached, "pixel limit must precede allocation")
        print("SCROLL SYNTHETIC TESTS OK: static, small motion, up/down, left/right, reversal, axis switch, pixel preservation, limit")

        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--ambiguous-horizontal" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("-raw-frame.png") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            try check(files.count > 1, "missing horizontal regression frames")
            var replay: ScrollingImageStitcher?
            for file in files {
                let src = CGImageSourceCreateWithURL(file as CFURL, nil)!
                let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                if replay == nil { replay = ScrollingImageStitcher(image: image, maximumPixels: 100_000_000) }
                else {
                    let result = replay!.ingest(image, axis: .horizontal)
                    print("\(file.lastPathComponent): dx=\(result?.dx ?? 0) size=\(replay!.image.width)x\(replay!.image.height)")
                    try check(result == nil, "ambiguous repeated text must not create false horizontal offsets")
                }
                try check(replay!.image.width == image.width, "ambiguous horizontal canvas expanded")
            }
            print("AMBIGUOUS HORIZONTAL REPLAY OK: \(files.count) frames")
            return
        }
        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("-raw-frame.png") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var replay: ScrollingImageStitcher?
            var previousHeight = 0
            for file in files {
                let src = CGImageSourceCreateWithURL(file as CFURL, nil)!
                let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                if replay == nil { replay = ScrollingImageStitcher(image: image, maximumPixels: 100_000_000) }
                else {
                    let result = replay!.ingest(image)
                    print("\(file.lastPathComponent): dx=\(result?.dx ?? 0) dy=\(result?.dy ?? 0) score=\(result?.score ?? -1) size=\(replay!.image.width)x\(replay!.image.height)")
                    try check(result?.dx ?? 0 == 0, "real vertical capture misclassified horizontal")
                }
                try check(replay!.image.width == image.width && replay!.image.height >= previousHeight,
                          "real replay shrank canvas or added side strips")
                previousHeight = replay!.image.height
            }
            try check(files.count == 17 && previousHeight > 5000, "real replay failed to accumulate content")
            if CommandLine.arguments.count > 2 {
                let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL,
                    UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, replay!.image, nil)
                try check(CGImageDestinationFinalize(destination), "write replay output")
            }
            print("SCROLL REAL REPLAY OK: \(files.count) frames; final \(replay!.image.width)x\(replay!.image.height)")
        }
    }
}
