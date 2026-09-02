// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OSLog

/// Explicitly requested local, lossless screenshot diagnostics. No uploads.
/// Each scrolling session owns its trace, including subsequent editor handoffs.
final class ScreenshotCaptureTrace: @unchecked Sendable {
    static let enabledKey = "screenshotDiagnosticsEnabled"
    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Vorssaint/ScreenshotDiagnostics", isDirectory: true)
    }
    private let queue = DispatchQueue(label: "ScreenshotCaptureTrace", qos: .utility)
    let directory: URL
    private var sequence = 0
    private var bytes = 0
    private var limited = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint", category: "ScreenshotTrace")
    private var enabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    init() {
        directory = Self.rootDirectory
            .appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)", isDirectory: true)
        event("session-start", details: "lossless PNG; local only; 2 GiB per session; image logging stops at limit")
        if enabled { log.notice("Screenshot diagnostics: \(self.directory.path, privacy: .public)") }
    }

    /// Synchronous serialization deliberately applies backpressure instead of
    /// dropping diagnostic frames or retaining unbounded full-resolution images.
    func event(_ stage: String, image: CGImage? = nil, details: String = "") {
        guard enabled else { return }
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                sequence += 1
                var record: [String: Any] = ["sequence": sequence, "stage": stage,
                    "time": Date().timeIntervalSince1970,
                    "uptime": ProcessInfo.processInfo.systemUptime, "details": details]
                if let image {
                    record["width"] = image.width; record["height"] = image.height
                    record["imageObject"] = String(describing: ObjectIdentifier(image))
                    if !limited {
                        let data = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
                        else { throw CocoaError(.fileWriteUnknown) }
                        CGImageDestinationAddImage(destination, image, nil)
                        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                        if bytes + data.length <= 2 * 1024 * 1024 * 1024 {
                            let name = String(format: "%06d", sequence) + "-" + stage + ".png"
                            try (data as Data).write(to: directory.appendingPathComponent(name), options: .atomic)
                            bytes += data.length; record["file"] = name
                        } else { limited = true }
                    }
                    if limited { record["imageOmitted"] = "session reached 2 GiB limit" }
                }
                let url = directory.appendingPathComponent("events.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                line.append(10); try handle.write(contentsOf: line)
            } catch {
                log.error("Screenshot trace write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
