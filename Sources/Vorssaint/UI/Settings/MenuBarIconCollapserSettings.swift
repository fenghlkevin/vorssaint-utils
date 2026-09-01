// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Dedicated settings surface for the installable menu bar organization
/// feature. Feature Hub owns whether this page exists; the toggle here owns
/// whether its divider is currently present.
struct MenuBarIconCollapserSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var collapser = MenuBarIconCollapser.shared

    private var strings: MenuBarIconCollapserStrings {
        .strings(for: l10n.language)
    }

    var body: some View {
        Form {
            Section {
                Toggle(strings.enable, isOn: Binding(
                    get: { collapser.isEnabled },
                    set: { collapser.setEnabled($0) }
                ))
                Text(strings.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if collapser.isEnabled {
                Section(strings.configuration) {
                    Text(strings.instruction)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker(strings.automaticCollapse, selection: Binding(
                        get: { collapser.autoCollapseDelay },
                        set: { collapser.setAutoCollapseDelay($0) }
                    )) {
                        ForEach(MenuBarIconCollapserSupport.allowedDelays, id: \.self) { seconds in
                            Text(strings.delayTitle(seconds)).tag(seconds)
                        }
                    }
                    HStack {
                        Button(collapser.isCollapsed ? strings.expand : strings.collapse) {
                            collapser.toggle()
                        }
                        Button(strings.checkPosition) {
                            collapser.refreshPlacement()
                        }
                    }
                    if collapser.placementError {
                        Text(strings.placementError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if collapser.placementIsSafe {
                        Text(strings.placementReady)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Section {
                Text(strings.interactionHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(strings.title)
        .onAppear { collapser.refreshPlacement() }
    }
}
