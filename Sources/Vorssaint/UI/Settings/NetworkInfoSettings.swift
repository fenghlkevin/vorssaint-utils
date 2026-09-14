// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct NetworkInfoSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = NetworkInfoService.shared
    @AppStorage(DefaultsKey.panelShowNetworkInfo) private var panelEntry = true
    private var text: NetworkInfoStrings { NetworkInfoStrings(language: l10n.language) }

    var body: some View {
        Form {
            Section {
                Text(text.summary).foregroundStyle(.secondary)
                Button(text.open) { (NSApp.delegate as? AppDelegate)?.showNetworkInfoPanel() }
                Toggle(text.panelEntry, isOn: $panelEntry)
            } header: { Text(text.title) }
            Section {
                Text(text.historyCaption).font(.caption).foregroundStyle(.secondary)
                if service.history.isEmpty {
                    Text(text.historyEmpty).foregroundStyle(.secondary)
                }
                ForEach(service.history) { record in
                    NetworkInfoHistoryRow(record: record, text: text) {
                        service.deleteHistory(record.id)
                    }
                }
                if !service.history.isEmpty {
                    Button(text.clearHistory, role: .destructive) { service.clearHistory() }
                }
            } header: { Text(text.historyTitle) }
            Section {
                Text(text.note)
                Text(text.privacy)
                Link(text.detailsSource, destination: URL(string: "https://ipwhois.io")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct NetworkInfoHistoryRow: View {
    let record: NetworkInfoHistoryRecord
    let text: NetworkInfoStrings
    let delete: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(record.queriedAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(copied ? text.copied : text.copyRecord) {
                    copy(recordText)
                    copied = true
                }
                Button(text.deleteRecord, role: .destructive, action: delete)
            }
            .controlSize(.small)
            ForEach(record.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(routeTitle(entry.route)).fontWeight(.medium)
                        if let result = entry.result {
                            Text(result.ip).monospaced().textSelection(.enabled)
                            Button { copy(result.ip) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help(text.copy)
                                .accessibilityLabel(text.copy)
                        }
                    }
                    if let result = entry.result {
                        Text(detailLines(result)).foregroundStyle(.secondary).textSelection(.enabled)
                        if let failure = result.lookupFailure {
                            Text(text.lookupFailed + " · " + text.failure(failure)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(entry.failure.map(text.failure) ?? text.unknown).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private func routeTitle(_ route: NetworkInfoRoute) -> String {
        route == .domestic ? text.domestic : text.international
    }

    private func detailLines(_ result: NetworkInfoResult) -> String {
        ["\(text.location)：\(result.details?.location ?? text.unknown)",
         "\(text.operatorName)：\(result.details?.operatorName ?? text.unknown)",
         "ASN：\(result.details?.asnDescription ?? text.unknown)"]
            .joined(separator: "\n")
    }

    private var recordText: String {
        var parts = [record.queriedAt.formatted(date: .numeric, time: .standard)]
        for entry in record.entries {
            parts.append(routeTitle(entry.route))
            if let result = entry.result {
                parts.append("IPv4: " + result.ip)
                parts.append(detailLines(result))
                if let host = result.probeHost { parts.append(host) }
                if let failure = result.lookupFailure { parts.append(text.failure(failure)) }
            } else {
                parts.append(entry.failure.map(text.failure) ?? text.unknown)
            }
        }
        return parts.joined(separator: "\n")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
