import AppKit
import Combine
import Security

/// Preferences and event entry points are owned by the main thread.
final class IslandPhonePushService: ObservableObject {
    static let shared = IslandPhonePushService()
    @Published var configuration: IslandPhonePushConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: Self.preferenceKey) }
        }
    }
    @Published private(set) var status = "尚未测试"
    @Published private(set) var testing = false
    private static let preferenceKey = "dynamicIsland.codexPhonePush"
    private let transport = IslandPhonePushTransport()
    private var queue: Task<Void, Never>?
    private init() {
        configuration = UserDefaults.standard.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode(IslandPhonePushConfiguration.self, from: $0) } ?? .init()
    }
    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Vorssaint") + ".codex-bark",
         kSecAttrAccount as String: "configuration"]
    }
    func loadSecrets() throws -> IslandPhonePushSecrets {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .init() }
        guard status == errSecSuccess, let data = result as? Data,
              let secrets = try? JSONDecoder().decode(IslandPhonePushSecrets.self, from: data) else { throw IslandPhonePushError.storage }
        return secrets
    }
    func saveSecrets(_ secrets: IslandPhonePushSecrets) throws {
        try IslandPhonePushPayload.validate(configuration, secrets)
        let data = try JSONEncoder().encode(secrets)
        let status = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw IslandPhonePushError.storage }
        } else if status != errSecSuccess { throw IslandPhonePushError.storage }
        self.status = "配置已保存"
    }
    private var isAway: Bool {
        if DynamicIslandService.shared.presentationSuspended { return true }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) >= 120
    }
    func notify(_ event: IslandPhoneEvent, session: CodexIslandSession) {
        let config = configuration
        guard config.enabled, event.isEnabled(in: config), !config.onlyWhenAway || isAway else { return }
        let content = IslandPhonePushPayload.content(event: event, sessionID: session.id, project: session.project,
                                                     title: session.title, detail: session.detail, includeDetails: config.includeDetails)
        enqueue(content: content, config: config, sessionID: session.id)
    }
    private func enqueue(content: [String: String], config: IslandPhonePushConfiguration, sessionID: String) {
        let request: URLRequest
        do { request = try IslandPhonePushPayload.request(config: config, secrets: loadSecrets(), content: content) }
        catch { status = (error as? IslandPhonePushError)?.localizedDescription ?? IslandPhonePushError.storage.localizedDescription; return }
        let previous = queue
        queue = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.configuration.enabled, self.configuration == config else { return }
            do {
                try await self.send(request)
                self.status = "Bark 已接受，请检查设备。"
            } catch { self.status = (error as? IslandPhonePushError)?.localizedDescription ?? IslandPhonePushError.network.localizedDescription }
        }
    }
    func test(secrets: IslandPhonePushSecrets) {
        guard !testing else { return }
        testing = true
        let config = configuration
        Task { @MainActor in
            defer { testing = false }
            do {
                let content = ["title": "Vorssaint 测试通知", "body": "Codex 的重要消息会通过 Bark 推送到这台 iPhone。", "group": "Vorssaint · Codex", "id": "vorssaint-test"]
                let request = try IslandPhonePushPayload.request(config: config, secrets: secrets, content: content)
                try await send(request)
                status = "Bark 已接受，请检查设备。"
            } catch { status = (error as? IslandPhonePushError)?.localizedDescription ?? IslandPhonePushError.network.localizedDescription }
        }
    }
    private func send(_ request: URLRequest) async throws {
        try await transport.send(request)
    }
}
