// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct AppTrafficEntry: Codable, Identifiable {
    let id: String
    var name: String
    var appPath: String?
    var downloaded: Double = 0
    var uploaded: Double = 0
    var children: [String: Double] = [:]
    var total: Double { downloaded + uploaded }
}

/// Durable totals only; instantaneous rates and process IDs never survive a launch.
struct AppTrafficLedger: Codable {
    let bootID: Int64
    let bootDate: Date
    let startedAt: Date
    var updatedAt: Date
    var interrupted = false
    var includesLoopbackSince: Date?
    var entries: [String: AppTrafficEntry] = [:]

    static func restore(_ data: Data?, bootID: Int64, bootDate: Date, now: Date) -> Self {
        if let data, var saved = try? JSONDecoder().decode(Self.self, from: data), saved.bootID == bootID {
            saved.interrupted = true
            return saved
        }
        return Self(bootID: bootID, bootDate: bootDate, startedAt: now, updatedAt: now)
    }

    mutating func add(id: String, name: String, appPath: String?, child: String,
                      down: Double, up: Double, now: Date) {
        guard down.isFinite, up.isFinite, down >= 0, up >= 0 else { return }
        var entry = entries[id] ?? AppTrafficEntry(id: id, name: name, appPath: appPath)
        entry.name = name
        entry.downloaded += down
        entry.uploaded += up
        entry.children[child, default: 0] += down + up
        entries[id] = entry
        updatedAt = now
    }
}
