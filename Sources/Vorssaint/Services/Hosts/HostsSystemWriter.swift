// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Used only in the signed privileged helper. The XPC request carries content,
/// never a filesystem path or executable command.
enum HostsSystemWriter {
    static func apply(_ request: HostsWriteRequest, path: String = "/private/etc/hosts",
                      backupDirectory: String, owner: uid_t = 0) throws -> String {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HostsFailure(message: "无法读取系统 Hosts。") }
        defer { close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == owner, original.st_nlink == 1, original.st_mode & 0o022 == 0,
              original.st_size <= HostsSupport.limit else { throw HostsFailure(message: "系统 Hosts 的类型、归属或权限异常，已拒绝写入。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.readToEnd(), let current = String(data: data, encoding: .utf8), current == request.expected else {
            throw HostsFailure(message: "系统 Hosts 已被其他工具修改。请刷新后检查再应用。")
        }
        let base = try HostsSupport.split(current).base
        guard !HostsSupport.issues(request.managedContent, base: base).contains(where: \.blocking) else {
            throw HostsFailure(message: "配置存在语法错误或域名冲突。")
        }
        let updated = try HostsSupport.compose(current: current, managed: request.managedContent)
        if updated == current { return updated }
        if mkdir(backupDirectory, 0o700) != 0 && errno != EEXIST { throw HostsFailure(message: "无法创建系统恢复备份目录。") }
        let directory = open(backupDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw HostsFailure(message: "系统备份目录异常。") }
        defer { close(directory) }
        var backupInfo = stat()
        guard fstat(directory, &backupInfo) == 0, backupInfo.st_uid == owner,
              backupInfo.st_mode & 0o077 == 0 else { throw HostsFailure(message: "系统备份目录权限异常。") }
        let backupName = UUID().uuidString + ".tmp"
        let backupFD = openat(directory, backupName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard backupFD >= 0 else { throw HostsFailure(message: "无法保存系统恢复备份。") }
        defer { close(backupFD); unlinkat(directory, backupName, 0) }
        try writeAll(data, descriptor: backupFD)
        guard fsync(backupFD) == 0, renameat(directory, backupName, directory, "previous.hosts") == 0,
              fsync(directory) == 0 else { throw HostsFailure(message: "系统备份未完整保存，未修改 Hosts。") }
        let temporary = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(".vorssaint-hosts-" + UUID().uuidString).path
        let output = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw HostsFailure(message: "无法创建 Hosts 临时文件。") }
        defer { close(output); unlink(temporary) }
        try writeAll(Data(updated.utf8), descriptor: output)
        guard fchown(output, original.st_uid, original.st_gid) == 0,
              fchmod(output, original.st_mode & 0o777) == 0, fsync(output) == 0 else {
            throw HostsFailure(message: "无法设置 Hosts 文件权限。")
        }
        var latest = stat()
        try handle.seek(toOffset: 0)
        guard lstat(path, &latest) == 0, latest.st_ino == original.st_ino, latest.st_dev == original.st_dev,
              latest.st_mode == original.st_mode, latest.st_uid == original.st_uid,
              try handle.readToEnd() == data else {
            throw HostsFailure(message: "写入前检测到系统 Hosts 发生变化，请刷新后重试。")
        }
        guard rename(temporary, path) == 0 else { throw HostsFailure(message: "系统 Hosts 写入失败，原文件已保留。") }
        return updated
    }
    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HostsFailure(message: "Hosts 文件保存失败。") }
                offset += count
            }
        }
    }
}
