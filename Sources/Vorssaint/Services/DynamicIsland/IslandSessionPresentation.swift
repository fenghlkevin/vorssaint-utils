import Foundation

struct CodexIslandSession: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case running, waiting, completed, failed }
    let id: String
    var project: String
    var title: String
    var detail: String
    var status: Status
    var startedAt: Date
    var updatedAt: Date
}

/// Shared sizing and priority rules for the visible panel and pointer hit region.
enum IslandSessionPresentation {
    static let chromeHeight = 90.0
    static func rowHeight(_ session: CodexIslandSession) -> Double {
        session.status == .waiting ? 132 : 76
    }

    static func ordered(_ sessions: [CodexIslandSession]) -> [CodexIslandSession] {
        func rank(_ status: CodexIslandSession.Status) -> Int {
            switch status {
            case .waiting: return 0
            case .running: return 1
            case .failed: return 2
            case .completed: return 3
            }
        }
        return sessions.sorted {
            if rank($0.status) != rank($1.status) { return rank($0.status) < rank($1.status) }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    static func visible(_ sessions: [CodexIslandSession], enabled: Bool, compact: Bool) -> [CodexIslandSession] {
        guard enabled else { return [] }
        let sorted = ordered(sessions)
        return compact ? Array(sorted.prefix(1)) : sorted
    }

    static func height(for sessions: [CodexIslandSession], maximum: Double) -> Double {
        let content = sessions.isEmpty ? 100 : sessions.reduce(0) { $0 + rowHeight($1) }
        return min(min(max(maximum, 220), 560), chromeHeight + content)
    }
}

/// Full data stays available; only the default presentation is reduced.
struct IslandSessionPanelPlan {
    let primary: [CodexIslandSession]
    let recent: [CodexIslandSession]
    let focused: Bool
    let allCompleted: Bool

    init(sessions: [CodexIslandSession], focusedID: String?, now: Date) {
        let ordered = IslandSessionPresentation.ordered(sessions)
        let finished = !ordered.isEmpty && ordered.allSatisfy { $0.status == .completed }
        allCompleted = finished
        if let focusedID, let session = ordered.first(where: { $0.id == focusedID }) {
            primary = [session]; recent = []; focused = true
        } else {
            focused = false
            // Archive completed sessions only after five minutes without activity,
            // even when every visible session is complete.
            recent = ordered.filter { $0.status == .completed && now.timeIntervalSince($0.updatedAt) >= 300 }
            let recentIDs = Set(recent.map(\.id))
            primary = ordered.filter { !recentIDs.contains($0.id) }
        }
    }

    func height(maximum: Double, recentExpanded: Bool, visibleRows: Int = 3) -> Double {
        let rows = primary + (recentExpanded ? recent : [])
        let rowSpace = rows.isEmpty ? 100 : rows.prefix(min(max(visibleRows, 1), 3)).reduce(0.0) { $0 + IslandSessionPresentation.rowHeight($1) }
        let disclosure = !recent.isEmpty ? 30.0 : 0
        return min(max(maximum, 220), 90 + rowSpace + disclosure, 560)
    }
}
