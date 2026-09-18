import Foundation
import Darwin

private final class MemoryJournal: BatterySystemLimitJournal {
    var value: BatterySystemLimitRecord?
    var failSave = false
    func load() throws -> BatterySystemLimitRecord? { value }
    func save(_ record: BatterySystemLimitRecord) throws {
        if failSave { throw BatteryPowerUIError.journal }; value = record
    }
    func clear() throws { value = nil }
}
private final class Client: BatterySystemLimitClient {
    var limit = 100
    var delayed = false
    var failsAfterWrite = false
    var writes: [Int] = []
    let journal: MemoryJournal
    init(_ journal: MemoryJournal) { self.journal = journal }
    func availableLimits() throws -> [Int] { [80, 85, 90, 95, 100] }
    func read() throws -> BatterySystemLimitState { .init(limit: limit) }
    func setLimit(_ value: Int) throws {
        precondition(journal.value != nil, "journal must precede all writes")
        writes.append(value)
        if !delayed { limit = value }
        if failsAfterWrite { throw BatteryPowerUIError.unconfirmed }
    }
}
@main enum BatterySystemLimitTests {
    static func fails(_ block: () throws -> Void) -> Bool {
        do { try block(); return false } catch { return true }
    }
    static func main() throws {
        let journal = MemoryJournal()
        let device = Client(journal)
        let session = BatterySystemLimitSession(client: device, journal: journal)
        precondition(fails { _ = try session.apply(75) })
        precondition(device.writes.isEmpty && journal.value == nil)
        journal.failSave = true
        precondition(fails { _ = try session.apply(85) })
        precondition(device.writes.isEmpty)
        journal.failSave = false
        let applied = try session.apply(85)
        precondition(applied && device.limit == 85 && journal.value?.original == 100)
        _ = try session.apply(85)
        precondition(device.writes == [85], "no repeated writes on status polls")
        _ = try session.apply(90)
        precondition(journal.value?.original == 100 && device.writes == [85, 90])
        // Process restart restores the persisted original, not the latest target.
        let restarted = BatterySystemLimitSession(client: device, journal: journal)
        let restored = try restarted.restore()
        precondition(restored && device.limit == 100 && journal.value == nil)

        device.delayed = true
        let pending = try session.apply(85)
        precondition(!pending && session.confirmedLimit == nil)
        let count = device.writes.count
        _ = try session.apply(85)
        precondition(device.writes.count == count)
        device.limit = 85
        let confirmed = try session.apply(85)
        precondition(confirmed)
        // Another tool's edit is not overwritten, including during restoration.
        device.limit = 95
        precondition(fails { _ = try session.apply(85) })
        precondition(fails { _ = try session.restore() })
        precondition(device.writes.count == count && journal.value != nil)
        device.limit = 85; device.delayed = false
        _ = try session.restore()
        device.failsAfterWrite = true
        precondition(fails { _ = try session.apply(80) })
        precondition(journal.value?.original == 100 && device.limit == 80)
        device.failsAfterWrite = false
        _ = try BatterySystemLimitSession(client: device, journal: journal).restore()
        precondition(device.limit == 100 && journal.value == nil)

        // Real journal persistence and metadata checks, inside a unique fixture.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("battery-journal-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = BatterySystemLimitFileJournal(directory: folder.path, owner: geteuid())
        precondition(tryLoad(file) == nil && !file.mayExist)
        try file.save(.init(original: 100, previous: 100, target: 85))
        let reopened = BatterySystemLimitFileJournal(directory: folder.path, owner: geteuid())
        precondition(tryLoad(reopened)?.original == 100 && reopened.mayExist)
        try reopened.clear()
        let path = folder.appendingPathComponent(BatterySystemLimitFileJournal.filename)
        try Data("corrupt".utf8).write(to: path)
        precondition(fails { _ = try file.load() })
        precondition(fails { try file.save(.init(original: 100, previous: 100, target: 85)) })
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "/dev/null")
        precondition(fails { _ = try file.load() })
        print("PowerUI sessions: range, journal-before-write, no-repeat, delayed readback, restart, external edit, partial write and file safety passed")
    }
    private static func tryLoad(_ file: BatterySystemLimitFileJournal) -> BatterySystemLimitRecord? {
        do { return try file.load() } catch { preconditionFailure("unexpected journal failure: \(error)") }
    }
}
