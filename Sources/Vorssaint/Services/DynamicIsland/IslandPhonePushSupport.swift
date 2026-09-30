import Foundation
import CryptoKit

struct IslandPhonePushConfiguration: Codable, Equatable {
    var enabled = false
    var server = "https://api.day.app"
    var onlyWhenAway = true
    var approvals = true
    var questions = true
    var completions = true
    var warnings = true
    var includeDetails = false
    var encrypted = false
}

struct IslandPhonePushSecrets: Codable {
    var deviceKey = ""
    var encryptionKey = ""
    var encryptionIV = ""
}

enum IslandPhoneEvent: String, Codable {
    case approval, question, completed, warning
    var title: String {
        switch self {
        case .approval: return "Codex 等待审批"
        case .question: return "Codex 有问题需要回答"
        case .completed: return "Codex 任务完成"
        case .warning: return "Codex 任务提醒"
        }
    }
    func isEnabled(in config: IslandPhonePushConfiguration) -> Bool {
        switch self {
        case .approval: return config.approvals
        case .question: return config.questions
        case .completed: return config.completions
        case .warning: return config.warnings
        }
    }
}

enum IslandPhonePushError: Error, LocalizedError {
    case server, key, encryption, storage, rejected(Int), network
    var errorDescription: String? {
        switch self {
        case .server: return "请填写有效的 HTTPS Bark 服务器地址（不含设备密钥、查询参数）。"
        case .key: return "请填写 Bark 首页 URL 中的设备密钥，不是 Device Token。"
        case .encryption: return "加密需要 32 个 ASCII 字符的 Key 和 12 个 ASCII 字符的 IV。"
        case .storage: return "无法读取或保存钥匙串中的 Bark 配置。"
        case .rejected(let code): return "Bark 未接受消息（状态码 \(code)），请检查服务器和设备密钥。"
        case .network: return "无法连接 Bark 服务，请检查网络后重试。"
        }
    }
}

enum IslandPhonePushPayload {
    static func notificationID(_ sessionID: String) -> String {
        "vorssaint-" + SHA256.hash(data: Data(sessionID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    static func endpoint(_ server: String) throws -> URL {
        guard var parts = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw IslandPhonePushError.server
        }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = parts.path.isEmpty ? "/push" : "/" + parts.path + "/push"
        guard let url = parts.url else { throw IslandPhonePushError.server }
        return url
    }
    static func validate(_ config: IslandPhonePushConfiguration, _ secrets: IslandPhonePushSecrets) throws {
        _ = try endpoint(config.server)
        guard !secrets.deviceKey.isEmpty, secrets.deviceKey.count <= 128,
              secrets.deviceKey.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }) else {
            throw IslandPhonePushError.key
        }
        if config.encrypted {
            guard secrets.encryptionKey.utf8.count == 32, secrets.encryptionIV.utf8.count == 12,
                  secrets.encryptionKey.unicodeScalars.allSatisfy(\.isASCII),
                  secrets.encryptionIV.unicodeScalars.allSatisfy(\.isASCII) else { throw IslandPhonePushError.encryption }
        }
    }
    static func randomASCII(count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in alphabet.randomElement(using: &generator)! })
    }
    static func content(event: IslandPhoneEvent, sessionID: String, project: String, title: String,
                        detail: String, includeDetails: Bool) -> [String: String] {
        var body = String(project.prefix(100))
        if includeDetails { body += "\n" + String(title.prefix(160)) + "\n" + String(detail.prefix(400)) }
        return ["title": event.title, "body": body, "group": "Vorssaint · Codex",
                "id": notificationID(sessionID), "level": event == .approval || event == .question ? "timeSensitive" : "active"]
    }
    static func request(config: IslandPhonePushConfiguration, secrets: IslandPhonePushSecrets,
                        content: [String: String]) throws -> URLRequest {
        try validate(config, secrets)
        var payload: [String: String] = content
        if config.encrypted {
            // Bark accepts a per-message ASCII IV. Never reuse the configured IV with GCM.
            let iv = randomASCII(count: 12)
            let nonce = try AES.GCM.Nonce(data: Data(iv.utf8))
            let box = try AES.GCM.seal(JSONEncoder().encode(content),
                                       using: SymmetricKey(data: Data(secrets.encryptionKey.utf8)), nonce: nonce)
            payload = ["ciphertext": (box.ciphertext + box.tag).base64EncodedString(), "iv": iv]
            payload["id"] = content["id"]
        }
        payload["isArchive"] = "1"
        payload["device_key"] = secrets.deviceKey
        var request = URLRequest(url: try endpoint(config.server))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }
    static func validateResponse(data: Data, status: Int) throws {
        guard (200..<300).contains(status),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = body["code"] as? Int, code == 200 else {
            throw IslandPhonePushError.rejected(status)
        }
    }
}

final class IslandPhonePushTransport: NSObject, URLSessionTaskDelegate {
    private var injectedSession: URLSession?
    private lazy var client: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    init(session: URLSession? = nil) { injectedSession = session }
    func send(_ request: URLRequest) async throws {
        do {
            let (data, response) = try await (injectedSession ?? client).data(for: request)
            try IslandPhonePushPayload.validateResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as IslandPhonePushError { throw error }
        catch { throw IslandPhonePushError.network }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
