import Foundation

@main
struct IslandSessionPresentationTests {
    static func main() {
        func session(_ id: String, _ status: CodexIslandSession.Status, _ time: Double) -> CodexIslandSession {
            CodexIslandSession(id: id, project: "Project", title: "Task", detail: "Activity",
                               status: status, startedAt: .distantPast,
                               updatedAt: Date(timeIntervalSince1970: time))
        }
        let sessions = [session("done", .completed, 100), session("run", .running, 80),
                        session("wait", .waiting, 10), session("fail", .failed, 90)]
        precondition(IslandSessionPresentation.ordered(sessions).map(\.id) == ["wait", "run", "fail", "done"])
        precondition(IslandSessionPresentation.visible(sessions, enabled: true, compact: true).map(\.id) == ["wait"])
        precondition(IslandSessionPresentation.visible(sessions, enabled: false, compact: false).isEmpty)
        precondition(IslandSessionPresentation.visible(sessions, enabled: true, compact: false).count == 4)
        let ties = [session("b", .running, 1), session("a", .running, 1), session("c", .running, 2)]
        precondition(IslandSessionPresentation.ordered(ties).map(\.id) == ["c", "a", "b"])
        precondition(IslandSessionPresentation.height(for: [], maximum: 560) == 190)
        precondition(IslandSessionPresentation.height(for: [sessions[1]], maximum: 560) == 166)
        precondition(IslandSessionPresentation.height(for: [sessions[2]], maximum: 560) == 222)
        precondition(IslandSessionPresentation.height(for: sessions, maximum: 220) == 220)
        let many = Array(repeating: sessions[1], count: 30)
        precondition(IslandSessionPresentation.height(for: many, maximum: 1000) == 560)
        precondition(IslandSessionPresentation.height(for: many, maximum: 0) == 220)
        let now = Date(timeIntervalSince1970: 1000)
        let mixed = [session("old", .completed, 700), session("fresh", .completed, 701), session("run", .running, 1), session("wait", .waiting, 2)]
        let plan = IslandSessionPanelPlan(sessions: mixed, focusedID: nil, now: now)
        precondition(plan.primary.map(\.id) == ["wait", "run", "fresh"])
        precondition(plan.recent.map(\.id) == ["old"])
        let focus = IslandSessionPanelPlan(sessions: mixed, focusedID: "old", now: now)
        precondition(focus.focused && focus.primary.map(\.id) == ["old"] && focus.recent.isEmpty)
        let done = IslandSessionPanelPlan(sessions: mixed.filter { $0.status == .completed }, focusedID: nil, now: now)
        precondition(done.allCompleted && done.primary.map(\.id) == ["fresh"] && done.recent.map(\.id) == ["old"])
        precondition(done.height(maximum: 560, recentExpanded: false) == 196)
        let overflow = IslandSessionPanelPlan(sessions: many, focusedID: nil, now: now)
        precondition(overflow.primary.count == 30)
        precondition(overflow.height(maximum: 560, recentExpanded: false) == 318)
        let missing = IslandSessionPanelPlan(sessions: mixed, focusedID: "removed", now: now)
        precondition(!missing.focused && missing.primary.count == 3)
        print("Island presentation tests passed: priorities, compact selection, disabled state, stable ordering and height bounds.")
    }
}
