// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct NetworkInfoSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = NetworkInfoService.shared
    @AppStorage(DefaultsKey.panelShowNetworkInfo) private var panelEntry = true
    private var text: NetworkInfoStrings { NetworkInfoStrings(language: l10n.language) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text.title).font(.title2.bold())
                        Text(text.overview).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(text.open) { (NSApp.delegate as? AppDelegate)?.showNetworkInfoPanel() }
                    Button { service.refresh(force: true) } label: {
                        Label(text.refresh, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(NetworkInfoRoute.allCases.allSatisfy { service.state($0).isLoading })
                }
                Toggle(text.panelEntry, isOn: $panelEntry)
                    .toggleStyle(.switch).padding(14).background(surface)
                Text(text.currentNetwork).font(.headline)
                if let date = service.restoredAt {
                    HStack {
                        Label(text.restoredResult, systemImage: "clock.arrow.circlepath")
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    }.font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    NetworkInfoLocalCard(addresses: service.localAddresses.filter { !$0.isTunnel }, failed: service.localAddressFailed, text: text)
                    NetworkInfoLocalCard(addresses: service.localAddresses.filter { $0.isTunnel }, failed: service.localAddressFailed, text: text, tunnel: true)
                    ForEach(NetworkInfoRoute.allCases) { route in
                        NetworkInfoRouteCard(route: route, state: service.state(route), text: text)
                    }
                }
                NetworkInfoTopologyView(service: service, text: text)
                HStack {
                    Text(text.historyTitle).font(.headline)
                    Spacer()
                    Button(text.clearHistory, role: .destructive) { service.clearHistory() }
                        .disabled(service.history.isEmpty)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.historyCaption).font(.caption).foregroundStyle(.secondary).padding(14)
                    Divider()
                    if service.history.isEmpty {
                        Text(text.historyEmpty).foregroundStyle(.secondary).padding(16)
                    } else {
                        HStack {
                            Text(text.time).frame(width: 125, alignment: .leading)
                            Text(text.localAndVPN).frame(maxWidth: .infinity, alignment: .leading)
                            Text(text.domestic).frame(maxWidth: .infinity, alignment: .leading)
                            Text(text.international).frame(maxWidth: .infinity, alignment: .leading)
                            Text(text.actions).frame(width: 58)
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(14)
                        ForEach(service.history) { record in
                            Divider()
                            NetworkInfoHistoryRow(record: record, text: text) { service.deleteHistory(record.id) }
                                .padding(14)
                        }
                    }
                }
                .background(surface)
                DisclosureGroup(text.detailsLabel) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text.note)
                        Text(text.privacy)
                        Link(text.detailsSource, destination: URL(string: "https://ipwhois.io")!)
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }.padding(14).background(surface)
            }.padding(24).frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
    }
}

private struct NetworkInfoHistoryRow: View {
    let record: NetworkInfoHistoryRecord
    let text: NetworkInfoStrings
    let delete: () -> Void
    @State private var copied = false

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        Text(record.queriedAt, format: .dateTime.month().day().hour().minute())
                    }
                }
                .buttonStyle(.plain).frame(width: 125, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    if let addresses = record.localAddresses {
                        if addresses.isEmpty { Text(text.localEmpty).foregroundStyle(.secondary) }
                        ForEach(addresses) { address in
                            ipButton(address.ip)
                            Text((address.isTunnel ? "VPN · " : "") + address.interface)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else { Text(text.notRecorded).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                ForEach(NetworkInfoRoute.allCases) { route in
                    VStack(alignment: .leading) {
                        if let entry = record.entries.first(where: { $0.route == route }) {
                            if let result = entry.result { ipButton(result.ip) }
                            else { Text(entry.failure.map(text.failure) ?? text.unknown).foregroundStyle(.secondary) }
                        } else { Text(text.notRecorded).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button { copy(recordText); copied = true } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }.help(text.copyRecord).accessibilityLabel(text.copyRecord)
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .help(text.deleteRecord).accessibilityLabel(text.deleteRecord)
                }.buttonStyle(.borderless).frame(width: 58)
            }.font(.system(size: 11))
            if expanded {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(record.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(routeTitle(entry.route)).fontWeight(.medium)
                            if let result = entry.result {
                                Text(detailLines(result)).textSelection(.enabled)
                                if let failure = result.lookupFailure {
                                    Text(text.lookupFailed + " · " + text.failure(failure)).foregroundStyle(.orange)
                                }
                            } else { Text(entry.failure.map(text.failure) ?? text.unknown) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(12)
                    .background(.blue.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func ipButton(_ ip: String) -> some View {
        HStack(spacing: 4) {
            Text(ip).monospaced().textSelection(.enabled)
            Button { copy(ip) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(text.copy).accessibilityLabel(text.copy + " " + ip)
        }
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
        parts.append(text.localAndVPN)
        if let addresses = record.localAddresses {
            parts.append(addresses.isEmpty ? text.localEmpty : addresses.map {
                ($0.isTunnel ? "VPN · " : "") + $0.interface + ": " + $0.ip
            }.joined(separator: "\n"))
        } else { parts.append(text.notRecorded) }
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
