// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit

protocol BatterySMCTransport: AnyObject {
    func key(named name: String) -> SMCClient.Key?
    func readBytes(_ key: SMCClient.Key) -> [UInt8]?
    func writeBytes(_ bytes: [UInt8], to key: SMCClient.Key) throws
}
extension SMCClient: BatterySMCTransport {}

/// Narrow allowlist; no arbitrary SMC keys or payloads cross XPC.
final class BatteryControlHardware {
    enum Failure: Error { case unsupported, readback, otherController }
    enum ProbeFailure: LocalizedError {
        case connection, missing, layout(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .connection: return "后台无法打开 AppleSMC，请检查系统访问权限后重试"
            case .missing: return "未识别到已适配的充电接口；不代表此机型不支持充电管理"
            case .layout(let key): return "\(key) 的数据格式与已适配接口不同，已阻止写入"
            case .unreadable(let key): return "已发现 \(key)，但读取失败，请重试或检查其他充电工具"
            }
        }
    }
    private let smc: BatterySMCTransport
    private let chargingKeys: [SMCClient.Key]
    private let adapter: SMCClient.Key?
    private let adapterOff: UInt8
    private let physicalPower: SMCClient.Key?
    private let modern: Bool
    private let led: SMCClient.Key?
    var ledSupported: Bool { led != nil }
    var dischargeSupported: Bool { adapter != nil && physicalPower != nil }
    var backendName: String { modern ? "Tahoe · CHTE" : "Legacy · CH0B/CH0C" }

    convenience init?(smc: BatterySMCTransport? = SMCClient()) {
        do { try self.init(validating: smc) } catch { return nil }
    }

    /// Choose by verified key layout, never by CPU name or macOS version.
    /// CHTE's bytes are a protocol payload, not a host-endian UInt32 value.
    init(validating smc: BatterySMCTransport?) throws {
        guard let smc else { throw ProbeFailure.connection }
        self.smc = smc
        if let key = smc.key(named: "CHTE") {
            guard key.dataSize == 4, key.dataType == "ui32" else { throw ProbeFailure.layout("CHTE") }
            chargingKeys = [key]; modern = true
        } else {
            let keys = ["CH0C", "CH0B"].compactMap { smc.key(named: $0) }
            guard keys.count == 2 else { throw ProbeFailure.missing }
            guard keys.allSatisfy({ $0.dataSize == 1 && $0.dataType == "ui8 " }) else {
                throw ProbeFailure.layout("CH0B/CH0C")
            }
            chargingKeys = keys; modern = false
        }
        if let key = smc.key(named: "CHIE") {
            guard key.dataSize == 1, key.dataType == "hex_" else { throw ProbeFailure.layout("CHIE") }
            adapter = key; adapterOff = 8
        } else if let key = smc.key(named: "CH0I") {
            guard key.dataSize == 1, key.dataType == "ui8 " else { throw ProbeFailure.layout("CH0I") }
            adapter = key; adapterOff = 1
        } else { adapter = nil; adapterOff = 0 }
        let power = smc.key(named: "AC-W")
        physicalPower = power?.dataSize == 1 && power?.dataType == "si8 " ? power : nil
        let led = smc.key(named: "ACLC")
        self.led = led?.dataSize == 1 && led?.dataType == "ui8 " ? led : nil
        for key in chargingKeys + [adapter].compactMap({ $0 }) {
            guard smc.readBytes(key)?.count == Int(key.dataSize) else { throw ProbeFailure.unreadable(key.name) }
        }
    }

    func physicalPowerConnected() -> Bool? {
        guard let physicalPower, let bytes = smc.readBytes(physicalPower) else { return nil }
        if bytes == [0] { return false }
        if bytes == [1] { return true }
        return nil
    }

    func validateUncontrolled() throws {
        guard try state() == .automatic else { throw Failure.otherController }
    }

    func state() throws -> BatteryCommand {
        let values = try chargingKeys.map { key -> [UInt8] in
            guard let bytes = smc.readBytes(key), bytes.count == Int(key.dataSize) else { throw Failure.readback }
            return bytes
        }
        let charging: Bool
        if values == chargingKeys.map({ Array(repeating: UInt8(0), count: Int($0.dataSize)) }) { charging = true }
        else if values == (modern ? [[1, 0, 0, 0]] : [[2], [2]]) { charging = false }
        else { throw Failure.otherController }
        if let adapter {
            guard let bytes = smc.readBytes(adapter), bytes.count == 1 else { throw Failure.readback }
            if bytes == [adapterOff] {
                guard charging else { throw Failure.otherController }
                return .discharge
            }
            guard bytes == [0] else { throw Failure.otherController }
        }
        return charging ? .automatic : .pause
    }

    func apply(_ command: BatteryCommand) throws {
        guard command != .discharge || (dischargeSupported && physicalPowerConnected() == true) else { throw Failure.unsupported }
        // Restore AC input first. Force-discharge is only enabled after both
        // inhibit keys were successfully reset, avoiding a partial disconnect.
        if let adapter { try smc.writeBytes([0], to: adapter) }
        for key in chargingKeys {
            let bytes: [UInt8] = command == .pause ? (modern ? [1, 0, 0, 0] : [2])
                : Array(repeating: 0, count: Int(key.dataSize))
            try smc.writeBytes(bytes, to: key)
        }
        if command == .discharge, let adapter { try smc.writeBytes([adapterOff], to: adapter) }
        guard try state() == (command == .full ? .automatic : command) else { throw Failure.readback }
    }

    /// Restores charging and AC isolation first. LED is cosmetic: failure is
    /// returned as a warning and must never keep the recovery journal active.
    @discardableResult func restore() throws -> Bool {
        // Attempt ALL resets even if the first write fails.
        var failed = false
        for key in [adapter].compactMap({ $0 }) + chargingKeys {
            do { try smc.writeBytes(Array(repeating: 0, count: Int(key.dataSize)), to: key) }
            catch { failed = true }
        }
        guard !failed, try state() == .automatic else { throw Failure.readback }
        guard led != nil else { return false }
        do { try setLED(0); return false } catch { return true }
    }

    func setLED(_ byte: UInt8) throws {
        guard [0, 3, 5].contains(byte), let led else { throw Failure.unsupported }
        try smc.writeBytes([byte], to: led)
        // Blink is a transient command, so no stable readback is expected.
        if byte != 5, smc.readBytes(led)?.first != byte { throw Failure.readback }
    }

    static func input() -> BatteryControlInput? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        func value(_ name: String) -> Any? {
            IORegistryEntryCreateCFProperty(battery, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let current = value("CurrentCapacity") as? NSNumber,
              let maximum = value("MaxCapacity") as? NSNumber, maximum.doubleValue > 0,
              let external = value("ExternalConnected") as? Bool,
              let charging = value("IsCharging") as? Bool else { return nil }
        let percent = Int((100 * current.doubleValue / maximum.doubleValue).rounded())
        guard (0...100).contains(percent) else { return nil }
        let temperature = (value("Temperature") as? NSNumber).map { $0.doubleValue / 100 }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var lidClosed = true // Unknown lid state must not permit forced discharge.
        if root != 0 {
            lidClosed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? true
            IOObjectRelease(root)
        }
        return BatteryControlInput(percent: percent, external: external, charging: charging,
                                   temperature: temperature, lidClosed: lidClosed)
    }
}
