// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct AwayLockPanelCard: View {
    @ObservedObject private var service = AwayLockService.shared
    @AppStorage(DefaultsKey.awayLockEnabled) private var enabled = false
    let collapsible: Bool

    var body: some View {
        PanelSection(.awayLock, title: AwayLockStrings.current.title, collapsible: collapsible) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(statusColor.opacity(0.13)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.statusText).font(.system(size: 12, weight: .semibold))
                        Text(service.detailText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                }
                if !service.selectedSignals.isEmpty {
                    ForEach(service.selectedSignals) { signal in
                        HStack(spacing: 6) {
                            Text(signal.name).lineLimit(1)
                            Spacer()
                            Text(signal.status).foregroundStyle(.secondary)
                            Text(signal.rssi.map { "\($0) dBm" } ?? "—")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                Divider()
                Button(service.isPaused ? "立即恢复" : "暂停 30 分钟") {
                    service.isPaused ? service.resumeNow() : service.pause(minutes: 30)
                }
                .buttonStyle(.bordered)
            }
            .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
        }
    }

    private var statusSymbol: String {
        switch service.state {
        case .nearby: return "lock.open.fill"
        case .weak, .countdown: return "exclamationmark.lock.fill"
        case .bluetoothUnavailable: return "antenna.radiowaves.left.and.right.slash"
        default: return "lock.fill"
        }
    }

    private var statusColor: Color {
        switch service.state {
        case .nearby: return .green
        case .weak, .countdown: return .orange
        case .bluetoothUnavailable: return .red
        default: return .secondary
        }
    }
}
