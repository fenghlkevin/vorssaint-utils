// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct BatterySystemLimitRecord: Codable {
    var version = 1
    let original: Int
    var previous: Int
    var target: Int
    var restoring = false
    var isValid: Bool {
        version == 1 && [original, previous, target].allSatisfy { (80...100).contains($0) && $0 % 5 == 0 }
    }
}

protocol BatterySystemLimitJournal {
    func load() throws -> BatterySystemLimitRecord?
    func save(_ record: BatterySystemLimitRecord) throws
    func clear() throws
}

/// Used only while holding BatteryOwnership's shared lock. A separate journal
/// distinguishes restoring a system preference from restoring SMC automatic mode.
final class BatterySystemLimitFileJournal: BatterySystemLimitJournal {
    static let directory = "/Library/Application Support/VorssaintBatteryControl"
    static let filename = "system-limit.json"
    private let directory: String
    private let owner: uid_t
    private var path: String { directory + "/" + Self.filename }
    init(directory: String = BatterySystemLimitFileJournal.directory, owner: uid_t = 0) {
        self.directory = directory; self.owner = owner
    }
    var mayExist: Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        return errno != ENOENT
    }
    private func checkDirectory(create: Bool) throws -> Bool {
        if create, mkdir(directory, 0o700) != 0, errno != EEXIST { throw BatteryPowerUIError.journal }
        var info = stat()
        if lstat(directory, &info) != 0 {
            if !create && errno == ENOENT { return false }
            throw BatteryPowerUIError.journal
        }
        guard info.st_uid == owner, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw BatteryPowerUIError.journal }
        return true
    }
    func load() throws -> BatterySystemLimitRecord? {
        guard try checkDirectory(create: false) else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }; throw BatteryPowerUIError.journal
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size < 4096 else { throw BatteryPowerUIError.journal }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == data.count, let value = try? JSONDecoder().decode(BatterySystemLimitRecord.self, from: data),
              value.isValid else { throw BatteryPowerUIError.journal }
        return value
    }
    func save(_ record: BatterySystemLimitRecord) throws {
        guard record.isValid else { throw BatteryPowerUIError.journal }
        _ = try checkDirectory(create: true)
        _ = try load() // Refuse replacing corrupt/unsafe existing records.
        let temporary = path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BatteryPowerUIError.journal }
        defer { close(fd); _ = unlink(temporary) }
        let data = try JSONEncoder().encode(record)
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0, rename(temporary, path) == 0 else { throw BatteryPowerUIError.journal }
        try syncDirectory()
    }
    private func syncDirectory() throws {
        let fd = open(directory, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BatteryPowerUIError.journal }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw BatteryPowerUIError.journal }
    }
    func clear() throws {
        guard try load() != nil else { return }
        guard unlink(path) == 0 else { throw BatteryPowerUIError.journal }
        try syncDirectory()
    }
}

/// No timers, sleeps, framework lookup or privilege in this state machine.
/// A journal is persisted BEFORE each attempted write, including restore.
final class BatterySystemLimitSession {
    private let client: BatterySystemLimitClient
    private let journal: BatterySystemLimitJournal
    private(set) var confirmedLimit: Int?
    init(client: BatterySystemLimitClient, journal: BatterySystemLimitJournal) {
        self.client = client; self.journal = journal
    }
    func apply(_ target: Int) throws -> Bool {
        guard try client.availableLimits().contains(target), (80...100).contains(target) else { throw BatteryPowerUIError.invalidValue }
        let current = try client.read().limit
        var record: BatterySystemLimitRecord
        if let saved = try journal.load() {
            guard !saved.restoring else { throw BatteryPowerUIError.unconfirmed }
            guard current == saved.target || current == saved.previous else { throw BatteryPowerUIError.externalChange }
            if saved.target == target {
                if current == target && saved.previous != target {
                    var confirmed = saved; confirmed.previous = target
                    try journal.save(confirmed)
                }
                confirmedLimit = current == target ? current : nil
                return current == target // Wait for readback, never re-write on every poll.
            }
            guard current == saved.target else { throw BatteryPowerUIError.unconfirmed }
            record = saved; record.previous = current; record.target = target
        } else {
            guard try client.availableLimits().contains(current) else { throw BatteryPowerUIError.invalidValue }
            record = .init(original: current, previous: current, target: target)
        }
        try journal.save(record)
        try client.setLimit(target)
        confirmedLimit = nil
        let actual = try client.read().limit
        guard actual == target || actual == current else { throw BatteryPowerUIError.externalChange }
        if actual == target {
            record.previous = target
            try journal.save(record)
        }
        confirmedLimit = actual == target ? actual : nil
        return actual == target
    }
    func restore() throws -> Bool {
        guard var record = try journal.load() else { return true }
        let current = try client.read().limit
        guard [record.original, record.previous, record.target].contains(current) else { throw BatteryPowerUIError.externalChange }
        if !record.restoring {
            record.restoring = true
            try journal.save(record)
            try client.setLimit(record.original)
        } else if current != record.original {
            // Explicit restoration retries are allowed; normal polling never
            // continuously overrides a user's external setting.
            try client.setLimit(record.original)
        }
        guard try client.read().limit == record.original else { return false }
        try journal.clear()
        confirmedLimit = record.original
        return true
    }
}
