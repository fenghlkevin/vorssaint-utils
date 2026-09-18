// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin

enum ProxyCore {
    static let version = "v1.19.31"
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }
    static var directory: URL { Bundle.main.resourceURL!.appendingPathComponent("ProxyCore", isDirectory: true) }
    static var executable: URL { directory.appendingPathComponent("mihomo-darwin-\(architecture)") }
    static func verify(executable: URL, manifest: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let root = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              root["version"] as? String == version,
              let entry = root[architecture] as? [String: String], let expected = entry["binarySHA256"] else {
            throw ProxyFailure.message("缺少固定版本代理核心。请使用包含 ProxyCore 的构建版本。")
        }
        let hash = SHA256.hash(data: try Data(contentsOf: executable, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard hash == expected else { throw ProxyFailure.message("代理核心校验失败，请重新构建或安装。") }
    }
    struct Validation: Sendable { let status: Int32; let timedOut: Bool }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private static func validateSync(executable: URL, work: URL, config: URL, timeout: TimeInterval, cancellation: Cancellation) -> Validation {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-t", "-d", work.path, "-f", config.path]
        process.currentDirectoryURL = work
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return Validation(status: -1, timedOut: false) }
        let deadline = Date().addingTimeInterval(timeout)
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            if cancellation.isCancelled || Date() >= deadline {
                process.terminate()
                if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
                return Validation(status: -1, timedOut: !cancellation.isCancelled)
            }
        }
        return Validation(status: process.terminationStatus, timedOut: false)
    }
    static func validate(executable: URL, work: URL, config: URL, timeout: TimeInterval = 120) async throws {
        let cancellation = Cancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                validateSync(executable: executable, work: work, config: config, timeout: timeout, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw ProxyFailure.message(result.timedOut ? "核心校验或 GEO 资源准备超时；未接管系统代理，请检查网络后重试。" : "Mihomo 配置校验失败。请检查节点字段、规则或 GEO 资源可用性；系统代理未变更。")
        }
    }

}

private final class ProxyNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class ProxyAPI: @unchecked Sendable {
    let port: Int
    let secret: String
    private let session: URLSession
    init(port: Int, secret: String, protocolClasses: [AnyClass]? = nil) {
        self.port = port; self.secret = secret
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0]
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.protocolClasses = protocolClasses
        session = URLSession(configuration: configuration, delegate: ProxyNoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func request(_ parts: [String], method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(string: "http://127.0.0.1:\(port)")!
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedPath = "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: safe)! }.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ProxyFailure.message("代理控制请求失败，请检查核心状态。") }
        guard data.count <= 8 * 1024 * 1024 else { throw ProxyFailure.message("核心响应超过大小限制。") }
        if data.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    func ready(requiredProviders: [String], deadline: Date) async throws {
        while Date() < deadline {
            try Task.checkCancellation()
            if let version = try? await request(["version"]), version["version"] as? String == ProxyCore.version {
                if requiredProviders.isEmpty { return }
                if let all = try? await request(["providers", "rules"]), let providers = all["providers"] as? [String: [String: Any]],
                   requiredProviders.allSatisfy({ (providers[$0]?["ruleCount"] as? Int ?? 0) > 0 }) { return }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ProxyFailure.message("核心或必要规则集尚未就绪，系统代理未启用。请重试以使用已缓存资源。")
    }
    func logSocket(level: String) -> URLSessionWebSocketTask { socket(path: "logs", query: [.init(name: "level", value: level)]) }
    func memorySocket() -> URLSessionWebSocketTask { socket(path: "memory", query: []) }
    private func socket(path: String, query: [URLQueryItem]) -> URLSessionWebSocketTask {
        var url = URLComponents(string: "ws://127.0.0.1:\(port)/\(path)")!
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request); task.maximumMessageSize = 65536
        return task
    }
    func groups() async throws -> [ProxyGroup] {
        let root = try await request(["proxies"])
        let proxies = root["proxies"] as? [String: [String: Any]] ?? [:]
        return proxies.keys.sorted().compactMap { name in
            guard let group = proxies[name], let members = group["all"] as? [String] else { return nil }
            return ProxyGroup(name: name, members: members, selected: group["now"] as? String ?? "")
        }
    }
}
