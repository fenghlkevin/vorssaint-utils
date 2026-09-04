// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private final class FakeBatterySMC: BatterySMCTransport {
    var values: [String: UInt8] = ["CH0I": 0, "CH0C": 0, "CH0B": 0, "ACLC": 0, "AC-W": 1]
    var writes: [(String, UInt8)] = []
    var failedKeys: Set<String> = []
    var ignoreWrites = false
    var wrongSize = false
    func key(named name: String) -> SMCClient.Key? {
        guard values[name] != nil else { return nil }
        return .init(code: 0, name: name, dataSize: wrongSize ? 2 : 1, dataType: name == "AC-W" ? "si8 " : "ui8 ")
    }
    func readBytes(_ key: SMCClient.Key) -> [UInt8]? { values[key.name].map { [$0] } }
    func writeBytes(_ bytes: [UInt8], to key: SMCClient.Key) throws {
        writes.append((key.name, bytes[0]))
        if failedKeys.contains(key.name) { throw BatteryControlHardware.Failure.readback }
        if !ignoreWrites { values[key.name] = bytes[0] }
    }
}

@main struct BatteryHardwareTests {
    static func main() throws {
        let transport = FakeBatterySMC()
        let hardware = BatteryControlHardware(smc: transport)!
        try hardware.validateUncontrolled()
        try hardware.apply(.pause)
        precondition(tryState(hardware) == .pause)
        precondition(transport.writes.map(\.0) == ["CH0I", "CH0C", "CH0B"])
        transport.writes = []
        try hardware.apply(.discharge)
        precondition(transport.writes.map(\.0) == ["CH0I", "CH0C", "CH0B", "CH0I"])
        precondition(transport.writes.map(\.1) == [0, 0, 0, 1])
        precondition(tryState(hardware) == .discharge)
        precondition(throwsError { try hardware.validateUncontrolled() })
        try hardware.restore()
        precondition(tryState(hardware) == .automatic)
        transport.failedKeys = ["ACLC"]
        let ledWarning = try hardware.restore()
        precondition(ledWarning, "LED failure must be a warning after control recovery")
        precondition(tryState(hardware) == .automatic)
        transport.failedKeys = ["CH0C"]; transport.writes = []
        precondition(throwsError { try hardware.apply(.discharge) })
        precondition(!transport.writes.contains { $0.0 == "CH0I" && $0.1 == 1 }, "Never disconnect AC after partial failure")
        transport.failedKeys = ["CH0I"]; transport.writes = []
        precondition(throwsError { try hardware.restore() })
        precondition(Set(transport.writes.map(\.0)) == ["CH0I", "CH0C", "CH0B"], "Try every control recovery key")
        transport.failedKeys = []; transport.ignoreWrites = true
        precondition(throwsError { try hardware.apply(.pause) }, "A successful transport without readback must fail")
        precondition(throwsError { try hardware.setLED(255) })
        transport.wrongSize = true
        precondition(BatteryControlHardware(smc: transport) == nil)
        transport.wrongSize = false; transport.values.removeValue(forKey: "CH0C")
        precondition(BatteryControlHardware(smc: transport) == nil)
        let noLED = FakeBatterySMC(); noLED.values.removeValue(forKey: "ACLC")
        precondition(BatteryControlHardware(smc: noLED)?.ledSupported == false)
        try testTahoe()
        print("Battery hardware: allowlist, write order, partial failure, recovery and readback tests passed (mock hardware)")
    }
    static func tryState(_ hardware: BatteryControlHardware) -> BatteryCommand? { try? hardware.state() }
    static func throwsError(_ action: () throws -> Void) -> Bool {
        do { try action(); return false } catch { return true }
    }
    static func testTahoe() throws {
        let smc = FakeTahoeSMC()
        let hardware = try BatteryControlHardware(validating: smc)
        precondition(hardware.backendName == "Tahoe · CHTE" && hardware.dischargeSupported)
        precondition(hardware.physicalPowerConnected() == true)
        try hardware.apply(.pause)
        precondition(smc.values["CHTE"] == [1, 0, 0, 0])
        precondition(smc.writes.map(\.0) == ["CHIE", "CHTE"])
        precondition(tryState(hardware) == .pause)
        precondition(throwsError { try hardware.validateUncontrolled() })
        smc.writes = []
        try hardware.apply(.discharge)
        precondition(smc.writes.map(\.0) == ["CHIE", "CHTE", "CHIE"])
        precondition(smc.values["CHIE"] == [8] && smc.values["CHTE"] == [0, 0, 0, 0])
        precondition(tryState(hardware) == .discharge)
        smc.values["AC-W"] = [0]
        precondition(hardware.physicalPowerConnected() == false)
        precondition(throwsError { try hardware.apply(.discharge) })
        try hardware.restore()
        precondition(tryState(hardware) == .automatic)
        smc.failedKeys = ["ACLC"]
        let ledWarning = try hardware.restore()
        precondition(ledWarning, "Tahoe LED failure must not block recovery")
        precondition(tryState(hardware) == .automatic)
        smc.values["AC-W"] = [1]; smc.failedKeys = ["CHTE"]; smc.writes = []
        precondition(throwsError { try hardware.apply(.discharge) })
        precondition(!smc.writes.contains { $0.0 == "CHIE" && $0.1 == [8] })
        smc.failedKeys = ["CHIE"]; smc.writes = []
        precondition(throwsError { try hardware.restore() })
        precondition(Set(smc.writes.map(\.0)) == ["CHIE", "CHTE"])
        smc.failedKeys = []; smc.ignoreWrites = true
        precondition(throwsError { try hardware.apply(.pause) })
        smc.ignoreWrites = false; smc.values["CHTE"] = [0, 0, 0, 1]
        precondition(throwsError { _ = try hardware.state() }, "Never guess UInt32 byte order")
        smc.values["CHTE"] = [0]
        precondition(BatteryControlHardware(smc: smc) == nil)
        smc.values["CHTE"] = [0, 0, 0, 0]; smc.types["CHTE"] = "flt "
        precondition(BatteryControlHardware(smc: smc) == nil)
        smc.types["CHTE"] = "ui32"; smc.unreadableKeys = ["CHTE"]
        precondition(BatteryControlHardware(smc: smc) == nil)
        smc.unreadableKeys = []; smc.values.removeValue(forKey: "CHIE")
        let chargeOnly = try BatteryControlHardware(validating: smc)
        precondition(!chargeOnly.dischargeSupported)
        try chargeOnly.apply(.pause)
        precondition(throwsError { try chargeOnly.apply(.discharge) })
        precondition(throwsError { _ = try BatteryControlHardware(validating: nil) })
        print("Tahoe: CHTE 4-byte payloads, CHIE isolation, capability split and fault handling passed")
    }
}

private final class FakeTahoeSMC: BatterySMCTransport {
    var values: [String: [UInt8]] = ["CHTE": [0, 0, 0, 0], "CHIE": [0], "ACLC": [0], "AC-W": [1]]
    var types = ["CHTE": "ui32", "CHIE": "hex_", "ACLC": "ui8 ", "AC-W": "si8 "]
    var writes: [(String, [UInt8])] = []
    var failedKeys: Set<String> = []
    var unreadableKeys: Set<String> = []
    var ignoreWrites = false
    func key(named name: String) -> SMCClient.Key? {
        guard let value = values[name] else { return nil }
        return .init(code: 0, name: name, dataSize: UInt32(value.count), dataType: types[name] ?? "????")
    }
    func readBytes(_ key: SMCClient.Key) -> [UInt8]? { unreadableKeys.contains(key.name) ? nil : values[key.name] }
    func writeBytes(_ bytes: [UInt8], to key: SMCClient.Key) throws {
        precondition(bytes.count == Int(key.dataSize))
        writes.append((key.name, bytes))
        if failedKeys.contains(key.name) { throw BatteryControlHardware.Failure.readback }
        if !ignoreWrites { values[key.name] = bytes }
    }
}
