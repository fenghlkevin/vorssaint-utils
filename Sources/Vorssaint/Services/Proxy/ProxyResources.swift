// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Bootstrap GEO before starting the core. Uses the current macOS network settings,
/// then keeps a checksum-verified local cache for subsequent/offline starts.
enum ProxyResources {
    static func prepare(_ inspection: ProxyInspection, work: URL) async throws {
        let rules = inspection.source["rules"] as? [String] ?? []
        let dns = inspection.source["dns"] as? [String: Any] ?? [:]
        let filter = dns["fallback-filter"] as? [String: Any] ?? [:]
        let needsGeo = rules.contains { $0.hasPrefix("GEOIP,") } || (dns["enable"] as? Bool == true && filter["geoip"] as? Bool != false)
        try await prepareProviders(inspection, work: work)
        guard needsGeo else { return }
        let file = work.appendingPathComponent("geoip.metadb")
        let checksum = work.appendingPathComponent("geoip.sha256")
        if let expected = try? String(contentsOf: checksum, encoding: .utf8),
           let data = try? Data(contentsOf: file, options: .mappedIfSafe), digest(data) == expected { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 75
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sources = [
            "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb",
            "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb"
        ]
        for source in sources {
            try Task.checkCancellation()
            do {
                let (temporary, response) = try await session.download(from: URL(string: source)!)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { continue }
                let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 1024, size < 128 * 1024 * 1024 else { continue }
                let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
                // MetaDB uses MaxMind DB metadata; reject HTML/error bodies before caching.
                let marker = Data([0xab, 0xcd, 0xef] + Array("MaxMind.com".utf8))
                guard data.suffix(131072).range(of: marker) != nil else { continue }
                // A full core -t immediately follows and validates the database structure.
                try ProxyFiles.write(data, to: file)
                try ProxyFiles.write(Data(digest(data).utf8), to: checksum)
                return
            } catch { if Task.isCancelled { throw CancellationError() } }
        }
        throw ProxyFailure.message("GEO 数据首次下载失败，系统代理未变更。请检查网络后重试；已缓存的数据可离线使用。")
    }
    private static func prepareProviders(_ inspection: ProxyInspection, work: URL) async throws {
        let providers = inspection.source["rule-providers"] as? [String: [String: Any]] ?? [:]
        guard !providers.isEmpty else { return }
        let directory = work.appendingPathComponent("ruleset")
        try ProxyFiles.directory(directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var jobs: [(String, URL, URL, Bool)] = []
        for name in providers.keys.sorted() {
            guard let text = providers[name]?["url"] as? String, let url = URL(string: text) else { continue }
            let file = work.appendingPathComponent(ProxyConfigCompiler.providerPath(name, providers[name]!))
            let attributes = try? file.resourceValues(forKeys: [.fileSizeKey])
            let exists = (attributes?.fileSize ?? 0) > 0
            // The core owns interval-based refresh and keeps its previous valid cache.
            // Bootstrap never replaces an existing cache, including during offline startup.
            if exists { continue }
            jobs.append((name, url, file, exists))
        }
        // Bounded first-download batches; existing caches are never overwritten here.
        for offset in stride(from: 0, to: jobs.count, by: 3) {
            let batch = Array(jobs[offset..<min(offset + 3, jobs.count)])
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (name, url, file, exists) in batch {
                    group.addTask {
                        do {
                            let (temporary, response) = try await session.download(from: url)
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw ProxyFailure.message("规则下载失败") }
                            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size > 0, size < 32 * 1024 * 1024 else { throw ProxyFailure.message("规则集大小无效") }
                            let data = try Data(contentsOf: temporary)
                            // Keep the original provider format; the core performs semantic validation.
                            try ProxyFiles.write(data, to: file)
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            if !exists && inspection.requiredProviders.contains(name) { throw ProxyFailure.message("必要规则集 \(name) 首次下载失败；系统代理未变更，请检查网络后重试。") }
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct ProxyResourceState: Identifiable {
    var id: String { name }
    let name: String
    let count: Int
    let updatedAt: String
    let behavior: String
}
extension ProxyAPI {
    func resources() async throws -> [ProxyResourceState] {
        let result = try await request(["providers", "rules"])
        let providers = result["providers"] as? [String: [String: Any]] ?? [:]
        return providers.keys.sorted().map { name in
            let item = providers[name]!
            return .init(name: name, count: item["ruleCount"] as? Int ?? 0, updatedAt: item["updatedAt"] as? String ?? "—", behavior: item["behavior"] as? String ?? "")
        }
    }
}
extension ProxyResources {
    static func copyCaches(from source: URL, to target: URL) throws {
        guard source.standardizedFileURL != target.standardizedFileURL else { return }
        try ProxyFiles.directory(target.appendingPathComponent("ruleset"))
        for file in (try? FileManager.default.contentsOfDirectory(at: source.appendingPathComponent("ruleset"), includingPropertiesForKeys: [.isRegularFileKey])) ?? [] {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let destination = target.appendingPathComponent("ruleset").appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: file, to: destination) }
        }
        for name in ["geoip.metadb", "geoip.sha256"] {
            let file = source.appendingPathComponent(name), destination = target.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: file, to: destination) }
        }
    }
}
