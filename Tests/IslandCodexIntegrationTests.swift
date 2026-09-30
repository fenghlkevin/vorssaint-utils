import Foundation
import CryptoKit

final class BarkMockProtocol: URLProtocol {
    static var status = 200
    static var response = Data("{\"code\":200}".utf8)
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct IslandCodexIntegrationTests {
    static func main() async throws {
        func rejects(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("expected rejection") } catch { }
        }
        func health(_ trust: String, command: String = "VorssaintDeveloper --vorssaint-codex-hook", enabled: Bool = true) throws -> CodexHookHealth {
            let response: [String: Any] = ["result": ["data": [["hooks": [["eventName": "permissionRequest", "command": command, "enabled": enabled, "trustStatus": trust]]]]]]
            return CodexHookHealth.parse(try JSONSerialization.data(withJSONObject: response))
        }
        let app = "/Applications/ChatGPT.app"
        let modern = app + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let legacy = app + "/Contents/Resources/codex"
        precondition(CodexHookHealth.executable(in: [app], isExecutable: { $0 == modern }) == modern)
        precondition(CodexHookHealth.executable(in: [app], isExecutable: { $0 == legacy }) == legacy)
        precondition(CodexHookHealth.executable(in: [app], isExecutable: { _ in false }) == nil)
        precondition(!CodexTaskActivity.containsTask([["type": "session_meta", "payload": ["cwd": "Resources"]]]))
        precondition(CodexTaskActivity.containsTask([["type": "event_msg", "payload": ["type": "task_started"]]]))
        let modified = try health("modified")
        let trusted = try health("trusted")
        let unrelated = try health("trusted", command: "vibe-island-bridge --source codex")
        let disabled = try health("trusted", enabled: false)
        precondition(modified == .needsTrust && trusted == .ready)
        precondition(unrelated == .missing && disabled == .missing)
        precondition(CodexHookHealth.parse(Data("{}".utf8)) == .unavailable)
        let input = Data("""
        {"hook_event_name":"PermissionRequest","session_id":"session/a","cwd":"/workspace/demo",
         "tool_name":"Bash","tool_input":{"command":"printf '你好'","description":"测试命令"}}
        """.utf8)
        let first = try CodexHookSupport.decode(input, environment: [:])!
        let second = try CodexHookSupport.decode(input, environment: [:])!
        precondition(first.approvalID != second.approvalID)
        precondition(first.operation == "printf '你好'" && first.detail == "测试命令")
        precondition(first.title.isEmpty && first.project == "demo")
        let root = URL(fileURLWithPath: "/private/tmp/island-test-responses")
        precondition(CodexHookSupport.responseURL(id: "../../escape", directory: root) == nil)
        precondition(CodexHookSupport.responseURL(id: first.approvalID!, directory: root) != nil)
        for decision in ["allow", "deny"] {
            let json = try JSONSerialization.jsonObject(with: CodexHookSupport.response(decision)!) as! [String: Any]
            let output = json["hookSpecificOutput"] as! [String: Any]
            precondition(output["hookEventName"] as? String == "PermissionRequest")
            precondition((output["decision"] as! [String: String])["behavior"] == decision)
            precondition(json["continue"] == nil && json["suppressOutput"] == nil)
        }
        let invalidDecision = try CodexHookSupport.response("yes")
        precondition(invalidDecision == nil)
        var question = CodexQuestionTracker()
        question.apply(["type": "response_item", "payload": ["type": "function_call", "name": "request_user_input", "call_id": "q1", "arguments": "{\"questions\":[{\"question\":\"发布到哪里？\"}]}"]])
        precondition(question.prompt == "发布到哪里？")
        question.apply(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "unrelated"]])
        precondition(question.callID == "q1")
        question.apply(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "q1"]])
        precondition(question.prompt == nil)
        var config = IslandPhonePushConfiguration()
        let secrets = IslandPhonePushSecrets(deviceKey: "fixture-key", encryptionKey: String(repeating: "k", count: 32), encryptionIV: "123456789012")
        for url in ["http://api.day.app", "https://user:pass@api.day.app", "https://api.day.app?key=secret", "file:///tmp/bark"] {
            rejects { _ = try IslandPhonePushPayload.endpoint(url) }
        }
        let nestedEndpoint = try IslandPhonePushPayload.endpoint("https://example.com/bark/")
        precondition(nestedEndpoint.absoluteString == "https://example.com/bark/push")
        let content = IslandPhonePushPayload.content(event: .approval, sessionID: "id", project: "项目", title: "私有标题", detail: "secret command", includeDetails: false)
        precondition(content["body"] == "项目" && !content.values.contains(where: { $0.contains("secret") }))
        let plain = try IslandPhonePushPayload.request(config: config, secrets: secrets, content: content)
        precondition(plain.httpMethod == "POST" && plain.url!.absoluteString == "https://api.day.app/push")
        precondition(!plain.url!.absoluteString.contains(secrets.deviceKey))
        precondition((try JSONDecoder().decode([String: String].self, from: plain.httpBody!))["isArchive"] == "1")
        config.encrypted = true
        let request = try IslandPhonePushPayload.request(config: config, secrets: secrets, content: content)
        let envelope = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
        precondition(envelope["title"] == nil && envelope["body"] == nil && envelope["group"] == nil)
        precondition(envelope["isArchive"] == "1")
        let encrypted = Data(base64Encoded: envelope["ciphertext"]!)!
        let nonce = try AES.GCM.Nonce(data: Data(envelope["iv"]!.utf8))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        let decoded = try AES.GCM.open(box, using: SymmetricKey(data: Data(secrets.encryptionKey.utf8)))
        let roundTrip = try JSONDecoder().decode([String: String].self, from: decoded)
        precondition(roundTrip == content)
        let again = try IslandPhonePushPayload.request(config: config, secrets: secrets, content: content)
        precondition(again.httpBody != request.httpBody)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [BarkMockProtocol.self]
        let transport = IslandPhonePushTransport(session: URLSession(configuration: sessionConfig))
        try await transport.send(request)
        precondition(BarkMockProtocol.requests.count == 1)
        BarkMockProtocol.response = Data("{\"code\":400,\"message\":\"do not expose device key\"}".utf8)
        do { try await transport.send(request); preconditionFailure("API failure accepted") }
        catch { precondition(!error.localizedDescription.contains("device key")) }
        BarkMockProtocol.status = 503
        do { try await transport.send(request); preconditionFailure("HTTP failure accepted") }
        catch { }
        print("Codex/Bark tests passed: request isolation, operation details, responses, question lifecycle, HTTPS validation, privacy, AES-GCM, notification IDs, mock HTTP success/failure.")
    }
}
