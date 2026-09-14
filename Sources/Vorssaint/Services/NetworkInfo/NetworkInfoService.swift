// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation
import Network

@MainActor
final class NetworkInfoService: ObservableObject {
    static let shared = NetworkInfoService()
    @Published private(set) var states: [NetworkInfoRoute: NetworkInfoState] = [:]
    @Published private(set) var history: [NetworkInfoHistoryRecord]
    private let historyDefaults: UserDefaults?
    private struct PendingHistory {
        let queriedAt: Date
        var remaining: Set<NetworkInfoRoute>
        var entries: [NetworkInfoHistoryEntry] = []
    }
    private var pendingHistory: [UUID: PendingHistory] = [:]
    private let client: NetworkInfoClient
    private let monitorsPathChanges: Bool
    private var tasks: [NetworkInfoRoute: Task<Void, Never>] = [:]
    private var generation = 0
    private var monitor: NWPathMonitor?
    private var hasInitialPath = false
    private var monitorID = UUID()

    init(client: NetworkInfoClient = NetworkInfoClient(), monitorsPathChanges: Bool = true,
         historyDefaults: UserDefaults? = .standard) {
        self.historyDefaults = historyDefaults
        history = NetworkInfoHistory.decode(historyDefaults?.data(forKey: NetworkInfoHistory.storageKey))
        self.client = client
        self.monitorsPathChanges = monitorsPathChanges
    }

    func state(_ route: NetworkInfoRoute) -> NetworkInfoState { states[route] ?? NetworkInfoState() }

    func refresh(force: Bool = false) {
        startMonitoring()
        let routes = NetworkInfoRoute.allCases.filter {
            tasks[$0] == nil && (force || state($0).needsRefresh(now: Date()))
        }
        guard !routes.isEmpty else { return }
        let batchID = UUID()
        pendingHistory[batchID] = PendingHistory(queriedAt: Date(), remaining: Set(routes))
        for route in routes {
            let serial = generation
            states[route, default: NetworkInfoState()].isLoading = true
            states[route, default: NetworkInfoState()].failure = nil
            tasks[route] = Task { [weak self] in
                guard let self else { return }
                defer { if generation == serial { tasks[route] = nil } }
                do {
                    let result = try await client.probe(route)
                    guard !Task.isCancelled, generation == serial else { return }
                    // Publish the new IP immediately; never attach the old IP's location to it.
                    states[route] = NetworkInfoState(result: result, isLoading: true)
                    do {
                        let details = try await client.lookup(ip: result.ip)
                        guard !Task.isCancelled, generation == serial else { return }
                        states[route]?.result?.details = details
                    } catch {
                        guard !Task.isCancelled, generation == serial else { return }
                        states[route]?.result?.lookupFailure = NetworkInfoSupport.failure(error)
                    }
                } catch {
                    guard !Task.isCancelled, generation == serial else { return }
                    states[route, default: NetworkInfoState()].failure = NetworkInfoSupport.failure(error)
                    states[route]?.isStale = states[route]?.result != nil
                }
                // A failed probe can leave an old result on screen; never save it as a new observation.
                completeHistory(batchID: batchID, entry: NetworkInfoHistoryEntry(
                    route: route, result: states[route]?.failure == nil ? states[route]?.result : nil,
                    failure: states[route]?.failure))
                states[route]?.isLoading = false
                states[route]?.attemptedAt = Date()
            }
        }
    }

    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        // Do not let a request that was already running recreate a just-cleared record.
        pendingHistory.removeAll()
        persistHistory()
    }

    private func completeHistory(batchID: UUID, entry: NetworkInfoHistoryEntry) {
        guard var batch = pendingHistory[batchID] else { return }
        batch.entries.append(entry)
        batch.remaining.remove(entry.route)
        if !batch.remaining.isEmpty {
            pendingHistory[batchID] = batch
            return
        }
        pendingHistory.removeValue(forKey: batchID)
        let entries = NetworkInfoRoute.allCases.compactMap { route in batch.entries.first { $0.route == route } }
        history = NetworkInfoHistory.normalized(history + [NetworkInfoHistoryRecord(
            id: batchID, queriedAt: batch.queriedAt, entries: entries)])
        persistHistory()
    }

    private func persistHistory() {
        guard let historyDefaults else { return }
        if history.isEmpty {
            historyDefaults.removeObject(forKey: NetworkInfoHistory.storageKey)
        } else if let data = try? JSONEncoder().encode(history) {
            historyDefaults.set(data, forKey: NetworkInfoHistory.storageKey)
        }
    }

    func stop() {
        pendingHistory.removeAll()
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        monitorID = UUID()
        monitor?.cancel()
        monitor = nil
        hasInitialPath = false
        states.removeAll()
    }

    private func startMonitoring() {
        guard monitorsPathChanges, monitor == nil else { return }
        let next = NWPathMonitor()
        let currentMonitorID = monitorID
        // Ignore the initial snapshot; subsequent changes invalidate in-flight work and cache.
        next.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, monitorID == currentMonitorID else { return }
                guard hasInitialPath else { hasInitialPath = true; return }
                networkDidChange()
            }
        }
        next.start(queue: DispatchQueue(label: "com.vorssaint.network-info-path", qos: .utility))
        monitor = next
    }

    func networkDidChange() {
        pendingHistory.removeAll()
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        for route in NetworkInfoRoute.allCases {
            states[route, default: NetworkInfoState()].isStale = true
            states[route]?.isLoading = false
            states[route]?.attemptedAt = nil
        }
    }
}
