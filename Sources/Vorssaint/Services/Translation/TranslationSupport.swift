// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security

enum TranslationProviderSelection {
    static let key = "translation.provider"
    static let providers = ["system", "ai", "codex"]

    static func ai(_ id: String) -> String { "ai:" + id }
    static func aiID(_ provider: String) -> String? {
        provider.hasPrefix("ai:") ? String(provider.dropFirst(3)) : nil
    }

    static func available(aiIDs: [String]) -> [String] {
        ["system"] + aiIDs.map(ai) + ["codex"]
    }

    static func restored(from defaults: UserDefaults, aiIDs: [String] = []) -> String {
        let saved = defaults.string(forKey: key) ?? "system"
        if saved == "ai", let first = aiIDs.first { return ai(first) }
        return available(aiIDs: aiIDs).contains(saved) ? saved : "system"
    }

    static func next(after current: String, backwards: Bool, aiIDs: [String] = []) -> String {
        let choices = available(aiIDs: aiIDs)
        let index = choices.firstIndex(of: current) ?? 0
        return choices[(index + (backwards ? choices.count - 1 : 1)) % choices.count]
    }
}

enum TranslationFailure: String, Error, LocalizedError {
    case invalidPackage, unsupportedAPI, invalidResult, unsupportedLanguage, timeout, networkDenied, network, storage, emptyInput
    var errorDescription: String? { "Translation: \(rawValue)" }
}

enum TranslationCredentials {
    struct Configuration: Codable { var options: [String: String] = [:]; var hosts: [String] = [] }
    static func load(_ id: String) throws -> Configuration {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return Configuration() }
        guard status == errSecSuccess, let data = value as? Data else { throw TranslationFailure.storage }
        return try JSONDecoder().decode(Configuration.self, from: data)
    }
    static func save(_ config: Configuration, id: String) throws {
        let data = try JSONEncoder().encode(config)
        let status = SecItemUpdate(base(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = base(id)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw TranslationFailure.storage }
        } else if status != errSecSuccess { throw TranslationFailure.storage }
    }
    static func remove(_ id: String) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TranslationFailure.storage }
    }
    private static func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Vorssaint") + ".translation",
         kSecAttrAccount as String: id]
    }
}

struct BobPluginManifest: Codable {
    struct Option: Codable, Identifiable {
        struct MenuValue: Codable { let title: String; let value: String }
        struct TextConfig: Codable { let type: String? }
        let identifier: String
        let type: String
        let title: String
        let defaultValue: String?
        let menuValues: [MenuValue]?
        let textConfig: TextConfig?
        var id: String { identifier }
    }
    let identifier: String
    let version: String
    let category: String
    let name: String
    let options: [Option]?
}

struct BobPluginPackage: Codable, Identifiable {
    let manifest: BobPluginManifest
    let files: [String: String]
    var id: String { manifest.identifier }

    func validate() throws {
        guard manifest.category == "translate", !manifest.name.isEmpty,
              manifest.name.count <= 160, !manifest.version.isEmpty,
              manifest.identifier.range(of: "^[a-z0-9]+(\\.[a-z0-9]+)*$", options: .regularExpression) != nil,
              manifest.identifier.count <= 160,
              files["main.js"] != nil, files.count <= 128,
              files.keys.allSatisfy(Self.safePath),
              files.values.reduce(0, { $0 + $1.utf8.count }) <= 8_000_000 else {
            throw TranslationFailure.invalidPackage
        }
        let options = manifest.options ?? []
        guard options.count <= 64, Set(options.map(\.identifier)).count == options.count,
              options.allSatisfy({ !$0.identifier.isEmpty && ["text", "menu"].contains($0.type)
                  && ($0.type != "menu" || !($0.menuValues ?? []).isEmpty) }) else {
            throw TranslationFailure.invalidPackage
        }
    }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.count < 512 && !path.hasPrefix("/")
            && !path.contains("\\") && !path.contains("\0")
            && !path.contains(where: { "*?[]:".contains($0) })
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Read ZIP members to stdout, never extract archive-controlled paths to disk.
    static func readArchive(_ url: URL) throws -> BobPluginPackage {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 8_000_000 else { throw TranslationFailure.invalidPackage }
        let archive = try Data(contentsOf: url)
        let members = try zipMembers(archive)
        var files: [String: String] = [:]
        for member in members where member.hasSuffix(".js") || member.hasSuffix(".json") {
            let data = try TranslationProcess.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-p", url.path, member], input: nil, timeout: 5, limit: 8_000_000)
            guard let text = String(data: data, encoding: .utf8) else { throw TranslationFailure.invalidPackage }
            files[member] = text
        }
        guard let info = files["info.json"]?.data(using: .utf8) else { throw TranslationFailure.invalidPackage }
        let package = BobPluginPackage(manifest: try JSONDecoder().decode(BobPluginManifest.self, from: info), files: files)
        try package.validate()
        return package
    }

    static func zipMembers(_ data: Data) throws -> [String] {
        func number(_ offset: Int, _ count: Int) -> Int {
            guard offset >= 0, offset + count <= data.count else { return -1 }
            return (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        guard data.count >= 22 else { throw TranslationFailure.invalidPackage }
        let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
            .first { number($0, 4) == 0x06054b50 && $0 + 22 + number($0 + 20, 2) == data.count }
        guard let end, number(end + 4, 2) == 0, number(end + 6, 2) == 0,
              number(end + 8, 2) == number(end + 10, 2) else { throw TranslationFailure.invalidPackage }
        let count = number(end + 10, 2)
        var offset = number(end + 16, 4)
        guard count > 0, count <= 128, offset >= 0,
              offset + number(end + 12, 4) == end else { throw TranslationFailure.invalidPackage }
        var paths: [String] = []
        var total = 0
        for _ in 0..<count {
            guard number(offset, 4) == 0x02014b50, offset + 46 <= end else { throw TranslationFailure.invalidPackage }
            let length = number(offset + 28, 2)
            let next = offset + 46 + length + number(offset + 30, 2) + number(offset + 32, 2)
            let size = number(offset + 24, 4)
            let unixType = (number(offset + 38, 4) >> 16) & 0xf000
            guard next <= end, size >= 0, size <= 8_000_000,
                  number(offset + 8, 2) & 1 == 0,
                  [0, 8].contains(number(offset + 10, 2)),
                  unixType == 0 || unixType == 0x8000 || unixType == 0x4000,
                  let path = String(data: data[(offset + 46)..<(offset + 46 + length)], encoding: .utf8)
            else { throw TranslationFailure.invalidPackage }
            let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard safePath(normalized), !paths.contains(path) else { throw TranslationFailure.invalidPackage }
            total += size
            guard total <= 8_000_000 else { throw TranslationFailure.invalidPackage }
            paths.append(path)
            offset = next
        }
        guard offset == end else { throw TranslationFailure.invalidPackage }
        return paths
    }
}

struct BobTranslationRequest: Codable {
    let package: BobPluginPackage
    let options: [String: String]
    let hosts: [String]
    let text: String
    let from: String
    let to: String
    let detectFrom: String
}

/// Owns only this invocation's process. A stopped JavaScript loop cannot strand the app.
final class TranslationProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    func run(executable: URL, arguments: [String], input: Data?, timeout: TimeInterval, limit: Int,
             environment: [String: String]? = nil, directory: URL? = nil,
             onOutput: ((Data) -> Void)? = nil) throws -> Data {
        let child = Process(), output = Pipe(), stdin = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        // No inherited credentials, proxy variables or user-script search paths.
        child.environment = environment ?? ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        child.currentDirectoryURL = directory
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        let watchdog = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        if let input {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else { throw TranslationFailure.invalidResult }
            data.append(chunk)
            onOutput?(chunk)
        }
        child.waitUntilExit()
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { throw TranslationFailure.timeout }
        guard child.terminationStatus == 0 else { throw TranslationFailure.invalidResult }
        return data
    }
    static func run(executable: URL, arguments: [String], input: Data?, timeout: TimeInterval, limit: Int) throws -> Data {
        let runner = TranslationProcess()
        return try withExtendedLifetime(runner) {
            try runner.run(executable: executable, arguments: arguments, input: input, timeout: timeout, limit: limit)
        }
    }
}
