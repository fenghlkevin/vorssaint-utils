// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct NetworkInfoView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service: NetworkInfoService

    init(service: NetworkInfoService) {
        self.service = service
    }
    private var text: NetworkInfoStrings { NetworkInfoStrings(language: l10n.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(text.title, systemImage: "network")
                    .font(.headline)
                Spacer()
                Button { service.refresh(force: true) } label: {
                    Label(text.refresh, systemImage: "arrow.clockwise")
                }
                .disabled(NetworkInfoRoute.allCases.allSatisfy { service.state($0).isLoading })
            }
            ForEach(NetworkInfoRoute.allCases) { route in
                NetworkInfoRouteCard(route: route, state: service.state(route), text: text)
            }
            if let first = service.state(.domestic).result,
               let second = service.state(.international).result,
               first.ip == second.ip,
               !service.state(.domestic).isStale, !service.state(.international).isStale,
               !service.state(.domestic).isLoading, !service.state(.international).isLoading {
                Label(text.sameIP, systemImage: "equal.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(text.detailsLabel) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text.note)
                    Text(text.privacy)
                    Link(text.detailsSource, destination: URL(string: "https://ipwhois.io")!)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .onAppear { service.refresh() }
    }
}

private struct NetworkInfoRouteCard: View {
    let route: NetworkInfoRoute
    let state: NetworkInfoState
    let text: NetworkInfoStrings
    @State private var copiedIP: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(route == .domestic ? text.domestic : text.international)
                    .font(.headline)
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.small)
                    Text(text.loading).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(state.result?.probeHost ?? route.probes.compactMap { $0.url.host }.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
            if let result = state.result {
                HStack {
                    Text(result.ip).font(.system(size: 14, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Text("IPv4").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.ip, forType: .string)
                        copiedIP = result.ip
                    } label: {
                        Image(systemName: copiedIP == result.ip ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help(copiedIP == result.ip ? text.copied : text.copy)
                    .accessibilityLabel(copiedIP == result.ip ? text.copied : text.copy)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    detail(text.location, result.details?.location)
                    detail(text.operatorName, result.details?.operatorName)
                    detail("ASN", result.details?.asnDescription)
                }
                .font(.system(size: 11))
                HStack(spacing: 5) {
                    Text(text.updated)
                    Text(result.checkedAt, style: .date)
                    Text(result.checkedAt, style: .time)
                }
                .font(.caption).foregroundStyle(.secondary)
                if let failure = result.lookupFailure {
                    Text(text.lookupFailed + " · " + text.failure(failure))
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if !state.isLoading && state.failure == nil {
                Text(text.notChecked).font(.callout).foregroundStyle(.secondary)
            }
            if state.isStale {
                Text(text.stale).font(.caption).foregroundStyle(.orange)
            }
            if let failure = state.failure {
                Text(text.failure(failure)).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func detail(_ title: String, _ value: String?) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value ?? text.unknown).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
