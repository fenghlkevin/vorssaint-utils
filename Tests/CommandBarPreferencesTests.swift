// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main
struct CommandBarPreferencesTests {
    static func main() {
        let sources: [CommandBarSource] = [.actions, .apps, .actions, .files, .calculator]
        precondition(CommandBarPreferences.orderedIndexes(sources: sources, orderRaw: "") == [0, 1, 2, 3, 4])
        precondition(CommandBarPreferences.orderedIndexes(sources: sources, orderRaw: "files,apps") == [3, 1, 0, 2, 4])
        let order = CommandBarPreferences.sourceOrder(from: " apps,apps,unknown,files ")
        precondition(Array(order.prefix(2)) == [.apps, .files])
        precondition(order.count == CommandBarSource.allCases.count)
        precondition(Set(order) == Set(CommandBarSource.allCases))
        precondition(CommandBarPreferences.sourceOrder(from: order.map(\.rawValue).joined(separator: ",")) == order)
        let disabled = CommandBarPreferences.storageValue(for: Set(CommandBarSource.allCases))
        precondition(CommandBarSource.allCases.allSatisfy {
            !CommandBarPreferences.isEnabled($0, disabledRaw: disabled)
        })
        precondition(CommandBarPreferences.isEnabled(.actions, disabledRaw: ""))
        precondition(!CommandBarPreferences.isEnabled(.actions, disabledRaw: "actions"))
        print("Command bar preferences tests passed")
    }
}
