import AppKit
// The harness links the production hook bridge, without launching services or installing hooks.
enum DefaultsKey { static let dynamicIslandCodexEnabled = "test.codex" }
final class DynamicIslandService {
    static let shared = DynamicIslandService()
    func activateCodex(duration: TimeInterval) {}
}
final class IslandPhonePushService {
    static let shared = IslandPhonePushService()
    func notify(_ kind: IslandPhoneEvent, session: CodexIslandSession) {}
    func resolve(sessionID: String) {}
}
enum AppleScriptRunner { static func runDetailed(_ script: String) {} }
@main struct CodexHookBridgeHarness {
    static func main() { CodexHookBridge.runAndExit() }
}
