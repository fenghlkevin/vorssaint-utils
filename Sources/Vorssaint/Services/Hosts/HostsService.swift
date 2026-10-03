// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine
import ServiceManagement

@MainActor final class HostsService: ObservableObject {
    private(set) static var loaded: HostsService?
    static var shared: HostsService {
        if let loaded { return loaded }
        let service = HostsService(); loaded = service; return service
    }
    @Published private(set) var profiles: [HostsProfile] = []
    @Published private(set) var backups: [HostsBackup] = []
    @Published private(set) var systemContent = ""
    @Published private(set) var hasSnapshot = false
    @Published private(set) var busy = false
    @Published var message = ""
    @Published private(set) var access = ""
    private var storageFailure = false
    private let helper = HostsHelperClient()
    private var root: URL? { PrivateFileStore.containerURL?.appendingPathComponent("Hosts", isDirectory: true) }
    private struct Store: Codable { var profiles: [HostsProfile]; var backups: [HostsBackup] }
    init() {
        if let root {
            let file = root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    let store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: file))
                    guard Set(store.profiles.map(\.id)).count == store.profiles.count else { throw HostsFailure(message: "配置标识重复。") }
                    profiles = store.profiles; backups = store.backups
                } catch { storageFailure = true; message = "Hosts 配置库读取失败，已禁止覆盖：\(error.localizedDescription)" }
            }
        }
        refresh()
    }
    var managedContent: String { (try? HostsSupport.split(systemContent).managed) ?? "" }
    var candidate: String { HostsSupport.aggregate(profiles) }
    var pending: Bool { !hasSnapshot || (try? HostsSupport.compose(current: systemContent, managed: candidate)) != systemContent }
    var issues: [HostsIssue] {
        do { return HostsSupport.issues(candidate, base: try HostsSupport.split(systemContent).base) }
        catch { return [.init(message: error.localizedDescription, blocking: true)] }
    }
    var canDisable: Bool { HostsHelperPolicy.canDisable(hasSnapshot: hasSnapshot, busy: busy, storageFailure: storageFailure, managedContent: managedContent, profiles: profiles) }
    var canApply: Bool { hasSnapshot && !busy && !storageFailure && !issues.contains(where: \.blocking) }
    func refresh() {
        guard !busy else { return }
        access = helper.accessText
        do {
            let url = URL(fileURLWithPath: "/etc/hosts")
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= HostsSupport.limit else { throw HostsFailure(message: "系统 Hosts 超过 1 MB。") }
            systemContent = try String(contentsOf: url, encoding: .utf8)
            _ = try HostsSupport.split(systemContent); hasSnapshot = true
        } catch { hasSnapshot = false; message = error.localizedDescription }
    }
    func authorize() {
        guard !busy else { return }
        busy = true; message = "正在验证 / 更新网络助手…"
        Task {
            defer { busy = false; refresh() }
            do { try await helper.authorize(); message = "网络助手连接已验证，可应用或停用 Hosts 配置。" }
            catch { helper.close(); message = error.localizedDescription }
        }
    }
    @discardableResult private func save() -> Bool {
        guard !storageFailure, let root, PrivateFileStore.createDirectory(at: root),
              let data = try? JSONEncoder().encode(Store(profiles: profiles, backups: backups)),
              PrivateFileStore.write(data, to: root.appendingPathComponent("library.json")) else {
            message = "Hosts 配置库未保存，操作已停止。"; return false
        }
        return true
    }
    @discardableResult func update(_ profile: HostsProfile) -> Bool {
        guard !busy, !storageFailure else { return false }
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "请输入配置名称。"; return false }
        let old = profiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        if save() { message = "配置已保存；点击“应用组合”使其生效。"; return true }
        profiles = old; return false
    }
    func delete(_ id: UUID) {
        guard !busy else { return }
        let old = profiles; profiles.removeAll { $0.id == id }
        if !save() { profiles = old } else { message = "配置已删除；系统中已应用的内容会在下次应用组合时更新。" }
    }
    func select(_ id: UUID, enabled: Bool, applyImmediately: Bool = false) {
        guard var profile = profiles.first(where: { $0.id == id }) else { return }
        profile.enabled = enabled
        if update(profile), applyImmediately { apply() }
    }
    func apply() { perform(content: candidate, restoring: nil) }
    func disable() {
        guard !busy, !storageFailure, AppFeature.hosts.isAvailable else { return }
        refresh()
        guard hasSnapshot else { return }
        let disabled = HostsHelperPolicy.disabledProfiles(profiles)
        // Pending selection is local state. No privileged write is necessary
        // when our managed block has never reached the system file.
        if managedContent.isEmpty {
            let previous = profiles; profiles = disabled
            if save() { message = "已取消全部待应用配置；系统原有记录保持不变。" }
            else { profiles = previous }
            return
        }
        perform(content: "", restoring: disabled)
    }
    func restore(_ backup: HostsBackup) {
        var restored = profiles.map { var item = $0; item.enabled = false; return item }
        if !backup.managedContent.isEmpty { restored.append(HostsProfile(name: "恢复 \(backup.date.formatted())", content: backup.managedContent, enabled: true)) }
        perform(content: backup.managedContent, restoring: restored)
    }
    private func perform(content: String, restoring: [HostsProfile]?) {
        guard !busy, hasSnapshot, !storageFailure, AppFeature.hosts.isAvailable else { return }
        do {
            guard helper.enabled else { throw HostsFailure(message: "请先授权网络助手，并在 macOS 登录项中批准，再刷新授权状态。") }
            let base = try HostsSupport.split(systemContent).base
            guard !HostsSupport.issues(content, base: base).contains(where: \.blocking) else { throw HostsFailure(message: "配置存在语法错误或域名冲突，请检查后再应用。") }
            let request = HostsWriteRequest(expected: systemContent, managedContent: content)
            backups.insert(HostsBackup(managedContent: managedContent, systemContent: systemContent), at: 0)
            backups = Array(backups.prefix(30))
            guard save() else { return }
            busy = true; message = "正在应用 Hosts…"
            Task {
                defer { busy = false }
                do {
                    let result = try await helper.write(request)
                    access = helper.accessText
                    guard result.success, let content = result.content else { throw HostsFailure(message: result.message) }
                    systemContent = content
                    if let restoring { profiles = restoring }
                    let saved = save()
                    message = saved ? (result.message.isEmpty ? "Hosts 已应用，DNS 缓存已刷新。" : result.message) : "系统 Hosts 已应用，但配置库保存失败，请刷新并检查。"
                } catch { helper.close(); access = helper.accessText; message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
    func closeConnection() { helper.close() }
}
