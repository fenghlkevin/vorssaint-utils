// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct NetworkInfoHistoryEntry: Codable, Equatable, Identifiable {
    let route: NetworkInfoRoute
    let result: NetworkInfoResult?
    let failure: NetworkInfoFailure?
    var id: NetworkInfoRoute { route }
}

/// One actual refresh, grouping the domestic and international requests it started.
struct NetworkInfoHistoryRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let queriedAt: Date
    let entries: [NetworkInfoHistoryEntry]
    var localAddresses: [NetworkInfoLocalAddress]? = nil
}

enum NetworkInfoHistory {
    // Local history is intentionally not registered as a portable settings preference.
    static let storageKey = "networkInfoHistory"
    static let limit = 10

    static func decode(_ data: Data?) -> [NetworkInfoHistoryRecord] {
        guard let data, data.count <= 1_048_576,
              let records = try? JSONDecoder().decode([NetworkInfoHistoryRecord].self, from: data) else { return [] }
        return normalized(records)
    }

    static func normalized(_ records: [NetworkInfoHistoryRecord]) -> [NetworkInfoHistoryRecord] {
        var seen = Set<UUID>()
        return Array(records.filter { !$0.entries.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.queriedAt > $1.queriedAt }.prefix(limit))
    }
}
