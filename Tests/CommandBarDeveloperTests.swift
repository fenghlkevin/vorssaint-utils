// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

@main
struct CommandBarDeveloperTests {
    static func main() throws {
        if CommandLine.arguments.contains("--listener") { try listener(); return }
        try textTests()
        try largeJSONTests()
        builtinPreferencesTests()
        builtinSourceFilteringTests()
        try portTests()
        if CommandLine.arguments.contains("--integration") { try integrationTest() }
        print("Command bar developer and port tests passed")
    }

    static func expectError<E: Error & Equatable>(_ expected: E, _ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected \(expected)") }
        catch { precondition(error as? E == expected, "Unexpected error: \(error)") }
    }

    static func check(_ expression: @autoclosure () throws -> Bool) rethrows {
        let value = try expression()
        precondition(value)
    }

    static func textTests() throws {
        let transform = CommandBarDeveloperSupport.transform
        let json = "{\"emoji\":\"中文😀\",\"items\":[true,null,1],\"url\":\"https://a/b\"}"
        let pretty = try transform(.json, json, "", Date())
        precondition(pretty.contains("\n") && pretty.contains("中文😀"))
        try check(try transform(.jsonMinify, pretty, "", Date()) == json)
        try check(try transform(.json, "true", "", Date()) == "true")
        expectError(CommandBarDeveloperError.invalidJSON) { _ = try transform(.json, "{bad}", "", Date()) }
        let original = " 中文😀\nsecond\tline  "
        let encoded = try transform(.base64Encode, original, "", Date())
        try check(try transform(.base64Decode, "\n" + encoded + " ", "", Date()) == original)
        expectError(CommandBarDeveloperError.invalidBase64) { _ = try transform(.base64Decode, "%%%", "", Date()) }
        expectError(CommandBarDeveloperError.invalidUTF8) { _ = try transform(.base64Decode, "/w==", "", Date()) }
        try check(try transform(.base64Decode, "", "", Date()) == "")
        let url = "a+b /?&=中文😀"
        let escaped = try transform(.urlEncode, url, "", Date())
        precondition(escaped.hasPrefix("a%2Bb%20%2F%3F%26%3D"))
        try check(try transform(.urlDecode, escaped, "", Date()) == url)
        try check(try transform(.urlDecode, "a+b", "", Date()) == "a+b")
        expectError(CommandBarDeveloperError.invalidURL) { _ = try transform(.urlDecode, "%GG", "", Date()) }
        let seconds = try transform(.timestamp, "1700000000", "", Date())
        precondition(seconds.contains("2023-11-14T22:13:20.000Z"))
        try check(try transform(.timestamp, "1700000000000", "", Date()) == seconds)
        try check(try transform(.timestamp, "2023-11-14T22:13:20Z", "", Date()) == seconds)
        try check(try transform(.timestamp, "ms:1000", "", Date()).contains("1970-01-01T00:00:01.000Z"))
        try check(try transform(.timestamp, "-1", "", Date()).contains("1969-12-31T23:59:59.000Z"))
        try check(try transform(.timestamp, "", "", Date(timeIntervalSince1970: 0)).contains("Unix (ms): 0"))
        expectError(CommandBarDeveloperError.invalidTimestamp) { _ = try transform(.timestamp, "1e100", "", Date()) }
        expectError(CommandBarDeveloperError.invalidTimestamp) { _ = try transform(.timestamp, "not a date", "", Date()) }
        try check(UUID(uuidString: try transform(.uuid, "", "", Date())) != nil)
        try check(try transform(.diff, "a\nb", "a\nc", Date()) == "--- before\n+++ after\n  a\n- b\n+ c")
        try check(try transform(.diff, "a\n", "a", Date()).hasSuffix("- "))
        try check(try transform(.diff, "a\na\nb", "a\nb", Date()).contains("- a"))
        expectError(CommandBarDeveloperError.diffTooLarge) {
            _ = try transform(.diff, String(repeating: "x\n", count: 1500), String(repeating: "y\n", count: 1500), Date())
        }
        expectError(CommandBarDeveloperError.inputTooLarge) {
            _ = try transform(.base64Encode, String(repeating: "x", count: 262145), "", Date())
        }
        precondition(CommandBarDeveloperTool.match("json min {\"x\":1}")?.tool == .jsonMinify)
        precondition(CommandBarDeveloperTool.match("base64 encode  a ")?.input == " a ")
        precondition(CommandBarDeveloperTool.match("JSON\n{}")?.input == "{}")
        precondition(CommandBarDeveloperTool.match("jsonfile") == nil)
    }

    static func portTests() throws {
        precondition(CommandBarPortSupport.query("port 8080") == .port(8080))
        precondition(CommandBarPortSupport.query("端口 65535") == .port(65535))
        precondition(CommandBarPortSupport.query("port") == .needsPort)
        precondition(CommandBarPortSupport.query("portal") == .unrelated)
        for input in ["port 0", "port -1", "port 65536", "port 8;kill", "port 80 81", "port 999999999999999999999"] {
            precondition(CommandBarPortSupport.query(input) == .invalid)
        }
        let fixture = "p4321\ncprocess with spaces\nf12\nPTCP\nn*:8080\nf13\nPTCP\nn[::1]:8080\nf14\nPTCP\nn127.0.0.1:55000->127.0.0.1:8080\np4322\ncudp\nf4\nPUDP\nn127.0.0.1:8080->127.0.0.1:53\n"
        let rows = CommandBarPortSupport.parse(fixture, port: 8080)
        precondition(rows.count == 3 && rows[0].name == "process with spaces")
        precondition(rows[1].address == "[::1]:8080" && rows[2].transport == "UDP")
        let a = CommandBarPortProcess(pid: 4321, name: "node", path: "/tmp/node", startedAt: 100, sockets: [])
        let reused = CommandBarPortProcess(pid: 4321, name: "node", path: "/tmp/node", startedAt: 200, sockets: [])
        precondition(!CommandBarPortSupport.sameIdentity(a, reused))
        precondition(CommandBarPortSupport.sameIdentity(a, a))
        let protected = CommandBarPortProcess(pid: getpid(), name: "test", path: "/tmp/test", startedAt: 1, sockets: [])
        expectError(CommandBarPortError.protectedProcess) { try CommandBarPortSupport.forceKill(protected, port: 8080) }
    }

    static func largeJSONTests() throws {
        let text = "{\"payload\":\"" + String(repeating: "x", count: 12 * 1024 * 1024) + "needle-at-end\",\"nested\":{\"array\":[true,null,42]}}"
        let formatted = try CommandBarDeveloperSupport.transform(.json, input: text)
        let compact = try CommandBarDeveloperSupport.transform(.jsonMinify, input: formatted)
        let document = try CommandBarJSONDocument(text: compact)
        let matches = document.matches("NEEDLE-AT-END")
        precondition(matches.count == 1)
        precondition(document.nodes[matches[0]].summary.count < 510)
        precondition(document.ancestors(of: matches[0]) == [0])
        let boolean = document.matches("true")
        precondition(boolean.count == 1 && document.ancestors(of: boolean[0]).count == 3)
        precondition(document.matches("does-not-exist").isEmpty)
        precondition(document.matches("payload", cancelled: { true }).isEmpty)
        let scalar = try CommandBarJSONDocument(text: "null")
        precondition(scalar.nodes.count == 1 && scalar.nodes[0].value == "null")
        let array = "[" + Array(repeating: "{\"key\":\"value\",\"n\":123}", count: 200_000).joined(separator: ",") + "]"
        let many = try CommandBarJSONDocument(text: CommandBarDeveloperSupport.transform(.json, input: array))
        precondition(many.nodes.count == 600_001)
        precondition(many.matches("value").count == 200_000)
        precondition(CommandBarDeveloperSupport.inputLimit(for: .json) == 50 * 1024 * 1024)
        expectError(CommandBarDeveloperError.inputTooLarge) {
            _ = try CommandBarDeveloperSupport.transform(.base64Encode, input: text)
        }
        print("12 MB JSON, 600001 tree nodes, complete-value search and ancestor navigation verified")
    }

    static func builtinSourceFilteringTests() {
        // Reproduce the user's disabled Actions source with enabled mini apps.
        let disabled = CommandBarPreferences.disabledSources(from: "actions,clipboard,emoji,menus,quitApps,snippets")
        precondition(!CommandBarPreferences.isRowEnabled("action.ordinary", disabledSources: disabled))
        precondition(CommandBarPreferences.isRowEnabled("app.example", disabledSources: disabled))
        for tool in CommandBarBuiltinTool.allCases {
            precondition(CommandBarPreferences.isRowEnabled(tool.rowID, disabledSources: disabled))
        }
        var settings = CommandBarBuiltinPreferences.defaults
        for trigger in ["json", "jsonz"] {
            settings[.json]?.trigger = trigger
            let match = CommandBarBuiltinPreferences.match(trigger, in: settings)
            precondition(match?.tool == .json)
            precondition(CommandBarPreferences.isRowEnabled(match!.tool.rowID, disabledSources: disabled))
        }
        // Catalog construction uses the per-tool switch before source filtering.
        settings[.json]?.enabled = false
        let visible = CommandBarBuiltinTool.allCases.filter {
            CommandBarBuiltinPreferences.configuration($0, in: settings).enabled
                && CommandBarPreferences.isRowEnabled($0.rowID, disabledSources: disabled)
        }
        precondition(!visible.contains(.json) && visible.contains(.jsonMinify))
        precondition(CommandBarBuiltinPreferences.match("jsonz", in: settings) == nil)
    }

    static func builtinPreferencesTests() {
        typealias Preferences = CommandBarBuiltinPreferences
        var settings = Preferences.defaults
        precondition(settings.count == CommandBarBuiltinTool.allCases.count)
        precondition(CommandBarDeveloperTool.allCases.allSatisfy { CommandBarBuiltinTool(rawValue: $0.rawValue) != nil })
        precondition(Preferences.decode("invalid") == settings)
        precondition(Preferences.decode("{}") == settings)
        precondition(Preferences.validTrigger("  JSONX  ") == "jsonx")
        precondition(Preferences.validTrigger("开发工具_1") == "开发工具_1")
        for invalid in ["", "  ", "1json", "json;kill", "json\nnext", "json\tmin", String(repeating: "a", count: 33)] {
            precondition(Preferences.validTrigger(invalid) == nil)
        }
        precondition(Preferences.validation("BASE64 encode", for: .json, in: settings) == .duplicate(.base64Encode))
        settings[.json]?.trigger = "jsonx"
        settings[.urlEncode]?.enabled = false
        let restored = Preferences.decode(Preferences.encode(settings))
        precondition(restored == settings)
        let match = Preferences.match("JSONX  {\"x\":1} ", in: restored)
        precondition(match?.tool == .json && match?.input == " {\"x\":1} ")
        precondition(Preferences.match("json {}", in: restored) == nil)
        precondition(Preferences.match("jsonxfile", in: restored) == nil)
        precondition(Preferences.match("url encode text", in: restored) == nil)
        precondition(Preferences.match("url decode text", in: restored)?.tool == .urlDecode)
        settings[.json]?.enabled = false
        precondition(Preferences.match("jsonx {}", in: settings) == nil)
        settings = Preferences.defaults
        settings[.jsonMinify]?.enabled = false
        precondition(Preferences.match("json min {}", in: settings) == nil)
        precondition(Preferences.match("json {}", in: settings)?.tool == .json)
        precondition(Preferences.portQuery("端口 8080", in: settings) == "port 8080")
        settings[.port]?.trigger = "ports"
        precondition(Preferences.portQuery("ports 8080", in: settings) == "port 8080")
        precondition(Preferences.portQuery("port 8080", in: settings) == nil)
        precondition(Preferences.portQuery("端口 8080", in: settings) == nil)
        settings[.port]?.enabled = false
        precondition(Preferences.portQuery("ports 8080", in: settings) == nil)
        settings[.json]?.trigger = "uuid"
        let sanitized = Preferences.decode(Preferences.encode(settings))
        precondition(sanitized[.json]?.trigger == "json")
        precondition(sanitized[.port]?.enabled == false)
        precondition(Set(sanitized.values.map(\.trigger)).count == CommandBarBuiltinTool.allCases.count)
        print("Independent tool switches, custom triggers, conflicts and persistence verified")
    }

    /// Only creates, inspects and terminates this test's own child process.
    static func integrationTest() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--listener"]
        let pipe = Pipe()
        child.standardOutput = pipe
        try child.run()
        defer {
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        let ready = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = Int(ready.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            fatalError("Listener could not start: \(ready)")
        }
        let snapshot = try CommandBarPortSupport.scan(port: port)
        guard let target = snapshot.first(where: { $0.pid == child.processIdentifier }) else {
            fatalError("Child listener not found")
        }
        precondition(Set(target.sockets.map(\.transport)) == ["TCP", "UDP"])
        precondition(!target.path.isEmpty && target.startedAt != nil)
        let stale = CommandBarPortProcess(pid: target.pid, name: target.name, path: target.path,
                                         startedAt: (target.startedAt ?? 0) + 1, sockets: target.sockets)
        expectError(CommandBarPortError.staleProcess) { try CommandBarPortSupport.forceKill(stale, port: port) }
        precondition(child.isRunning)
        try CommandBarPortSupport.forceKill(target, port: port)
        child.waitUntilExit()
        precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        try check(try CommandBarPortSupport.scan(port: port).allSatisfy { $0.pid != target.pid })
        print("Live TCP/UDP lookup, stale identity rejection and SIGKILL verified")
    }

    static func listener() throws {
        let tcp = socket(AF_INET, SOCK_STREAM, 0)
        let udp = socket(AF_INET, SOCK_DGRAM, 0)
        guard tcp >= 0, udp >= 0 else { fatalError("socket failed: \(errno)") }
        defer { close(tcp); close(udp) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let tcpBind = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(tcp, $0, length) }
        }
        guard tcpBind == 0, listen(tcp, 4) == 0 else { fatalError("bind failed: \(errno)") }
        var size = length
        _ = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(tcp, $0, &size) }
        }
        let udpBind = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(udp, $0, length) }
        }
        guard udpBind == 0 else { fatalError("UDP bind failed: \(errno)") }
        FileHandle.standardOutput.write(Data("\(UInt16(bigEndian: address.sin_port))\n".utf8))
        Thread.sleep(forTimeInterval: 30)
    }
}
