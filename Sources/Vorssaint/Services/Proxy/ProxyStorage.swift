// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

enum ProxyFiles {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ProxyFailure.message("无法创建私有配置文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temp.path, url.path) == 0 else { throw ProxyFailure.message("无法保存配置文件。") }
    }
}
final class ProxyProfileStore {
    let root: URL
    init(root: URL) { self.root = root }
    var preferencesURL: URL { root.appendingPathComponent("preferences.json") }
    var indexURL: URL { root.appendingPathComponent("profiles.json") }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent("profiles/\(id.uuidString)", isDirectory: true) }
    func runtime(_ id: UUID) -> URL { directory(id).appendingPathComponent("runtime", isDirectory: true) }
    func original(_ id: UUID) -> URL { directory(id).appendingPathComponent("original.yaml") }
    func profiles() throws -> [ProxyProfile] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        return try JSONDecoder().decode([ProxyProfile].self, from: Data(contentsOf: indexURL))
    }
    func loadPreferences() throws -> ProxyPreferences {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else { return .init() }
        return try JSONDecoder().decode(ProxyPreferences.self, from: Data(contentsOf: preferencesURL))
    }
    func save(_ preferences: ProxyPreferences) throws {
        try preferences.validate(); try ProxyFiles.directory(root)
        try ProxyFiles.write(JSONEncoder().encode(preferences), to: preferencesURL)
    }
    func importProfile(data: Data, name: String) throws -> ProxyProfile {
        _ = try ProxyConfigCompiler.inspect(data)
        let profile = ProxyProfile(id: UUID(), name: String(name.prefix(200)), importedAt: Date())
        try ProxyFiles.directory(root); try ProxyFiles.directory(directory(profile.id))
        try ProxyFiles.write(data, to: original(profile.id))
        var index = try profiles(); index.append(profile)
        try ProxyFiles.write(JSONEncoder().encode(index), to: indexURL)
        return profile
    }
}
