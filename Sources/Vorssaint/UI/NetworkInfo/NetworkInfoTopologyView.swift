// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// An address relationship overview, not an inferred packet route.
struct NetworkInfoTopologyView: View {
    @ObservedObject var service: NetworkInfoService
    let text: NetworkInfoStrings
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 0) {
                        VStack(spacing: 8) {
                            Image(systemName: "laptopcomputer").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text(text.thisMac).font(.caption)
                        }.frame(width: 90)
                        VStack(spacing: 34) {
                            Rectangle().fill(.blue).frame(height: 1)
                            Rectangle().fill(.purple).frame(height: 1)
                        }.frame(width: 30).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 10) {
                            interfaces(tunnel: false)
                            interfaces(tunnel: true)
                        }.frame(minWidth: 190, maxWidth: .infinity)
                        Spacer(minLength: 24)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(text.exitObservation).font(.caption).foregroundStyle(.secondary)
                            exit(.domestic)
                            exit(.international)
                        }
                        .padding(12)
                        .frame(minWidth: 190, maxWidth: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }
                    HStack(spacing: 8) {
                        Path { path in
                            path.move(to: .zero)
                            path.addLine(to: CGPoint(x: 32, y: 0))
                        }.stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: 32, height: 1).accessibilityHidden(true)
                        Text(text.topologyLegend).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(minWidth: 580)
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 10)
        } label: {
            Text(text.topologyTitle).font(.headline)
        }
    }

    private func interfaces(tunnel: Bool) -> some View {
        let addresses = service.localAddresses.filter { $0.isTunnel == tunnel }
        let color: Color = tunnel ? .purple : .blue
        return VStack(alignment: .leading, spacing: 6) {
            Text(tunnel ? text.vpnTitle : text.localTitle).font(.caption).foregroundStyle(color)
            if addresses.isEmpty {
                Text(service.localAddressFailed ? text.localFailed : (tunnel ? text.vpnEmpty : text.localEmpty))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(addresses) { address in
                VStack(alignment: .leading, spacing: 2) {
                    Text(address.ip).monospaced().textSelection(.enabled)
                    Text(address.interface).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.5)))
    }

    private func exit(_ route: NetworkInfoRoute) -> some View {
        let state = service.state(route)
        return VStack(alignment: .leading, spacing: 4) {
            Label(route == .domestic ? text.domestic : text.international, systemImage: "globe")
                .foregroundStyle(route == .domestic ? .green : .orange)
            if let result = state.result {
                Text(result.ip).monospaced().textSelection(.enabled)
                if state.networkChanged { Text(text.networkChanged).font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text(state.isLoading ? text.loading : (state.failure.map(text.failure) ?? text.notChecked))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
