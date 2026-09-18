// SPDX-License-Identifier: GPL-3.0-or-later
// PowerUI selector discovery informed by BatFi 4.0.0 (MIT); see docs/battery-powerui.md.
import Foundation
import ObjectiveC

struct BatterySystemLimitState: Codable, Equatable {
    let limit: Int
}

protocol BatterySystemLimitClient {
    func availableLimits() throws -> [Int]
    func read() throws -> BatterySystemLimitState
    func setLimit(_ value: Int) throws
}

enum BatteryPowerUIError: LocalizedError {
    case unavailable, invalidABI(String), invalidValue, unconfirmed, externalChange, journal
    var errorDescription: String? {
        switch self {
        case .unavailable: return "PowerUI系统限充接口不可用"
        case .invalidABI(let name): return "PowerUI接口格式未适配：\(name)；未调用"
        case .invalidValue: return "系统未报告支持此充电上限；未修改，未自动提高目标"
        case .unconfirmed: return "系统充电设置尚未回读确认"
        case .externalChange: return "检测到其他工具或用户修改系统限充；已停止覆盖，恢复记录保留"
        case .journal: return "系统限充恢复记录不可安全读取或保存；未继续写入"
        }
    }
}

/// All calls stay in the privileged helper. No override API or sub-80 defaults writes.
final class BatteryPowerUI: BatterySystemLimitClient {
    private let client: NSObject
    private let type: AnyClass

    /// Does not instantiate a client or issue IPC/writes. Safe for failure reports.
    static func interfaceDiagnostics() -> String {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW | RTLD_LOCAL) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") else {
            return "PowerUI: framework/client unavailable; no writes"
        }
        let names = ["isMCLSupported", "availableChargeLimitsWithError:", "getMCLLimitWithError:",
                     "isMCLCurrentlyEnabled:", "setMCLLimit:error:", "enableMCL:", "disableMCL:"]
        return (["PowerUI: method discovery (not execution confirmation)"] + names.map { name in
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
                  let encoding = method_getTypeEncoding(method) else { return "\(name): missing" }
            return "\(name): \(String(cString: encoding))"
        }).joined(separator: "\n")
    }

    init() throws {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW | RTLD_LOCAL) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else {
            throw BatteryPowerUIError.unavailable
        }
        let initializer = NSSelectorFromString("initWithClientName:")
        guard let method = class_getInstanceMethod(cls, initializer),
              Self.matches(method, result: ["@"], arguments: ["@", ":", "@"]) else {
            throw BatteryPowerUIError.invalidABI("initWithClientName:")
        }
        guard let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeRetainedValue() as? NSObject,
              let object = allocated.perform(initializer, with: "Vorssaint" as NSString)?.takeUnretainedValue() as? NSObject else {
            throw BatteryPowerUIError.unavailable
        }
        client = object; type = cls
        let selector = NSSelectorFromString("isMCLSupported")
        let supported = try checked("isMCLSupported", result: ["B", "c"], arguments: ["@", ":"])
        typealias Query = @convention(c) (AnyObject, Selector) -> ObjCBool
        guard unsafeBitCast(method_getImplementation(supported), to: Query.self)(client, selector).boolValue else {
            throw BatteryPowerUIError.unavailable
        }
        // The standard-limit route changes only the limit, like BatFi's adopt
        // route. It never calls enable/disable or interprets the Q-valued state.
        _ = try checked("setMCLLimit:error:", result: ["B", "c"], arguments: ["@", ":", "C", "^@"])
        _ = try availableLimits()
        _ = try read()
    }

    private static func matches(_ method: Method, result: Set<String>, arguments: [String]) -> Bool {
        func normalized(_ value: UnsafeMutablePointer<CChar>?) -> String {
            guard let value else { return "" }; defer { free(value) }
            return String(cString: value).drop(while: { "rnNoORV".contains($0) }).description
        }
        guard result.contains(normalized(method_copyReturnType(method))),
              method_getNumberOfArguments(method) == arguments.count else { return false }
        return arguments.enumerated().allSatisfy { normalized(method_copyArgumentType(method, UInt32($0.offset))) == $0.element }
    }
    private func checked(_ name: String, result: Set<String>, arguments: [String]) throws -> Method {
        guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)),
              Self.matches(method, result: result, arguments: arguments) else { throw BatteryPowerUIError.invalidABI(name) }
        return method
    }
    func availableLimits() throws -> [Int] {
        let name = "availableChargeLimitsWithError:"
        let method = try checked(name, result: ["@"], arguments: ["@", ":", "^@"])
        typealias Query = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSArray?
        var error: NSError?
        let values = unsafeBitCast(method_getImplementation(method), to: Query.self)(client, NSSelectorFromString(name), &error)
        if let error { throw error }
        guard let numbers = values as? [NSNumber] else { throw BatteryPowerUIError.unavailable }
        let supported = numbers.filter { $0.doubleValue == Double($0.intValue) }
            .map(\.intValue).filter { (80...100).contains($0) && $0 % 5 == 0 }
        guard !supported.isEmpty else { throw BatteryPowerUIError.unavailable }
        return Array(Set(supported)).sorted()
    }
    func read() throws -> BatterySystemLimitState {
        let name = "getMCLLimitWithError:"
        let method = try checked(name, result: ["C"], arguments: ["@", ":", "^@"])
        typealias Query = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt8
        var error: NSError?
        let value = unsafeBitCast(method_getImplementation(method), to: Query.self)(client, NSSelectorFromString(name), &error)
        if let error { throw error }
        guard (80...100).contains(Int(value)), value % 5 == 0 else { throw BatteryPowerUIError.invalidValue }
        return .init(limit: Int(value))
    }
    func setLimit(_ value: Int) throws {
        guard geteuid() == 0, try availableLimits().contains(value) else { throw BatteryPowerUIError.invalidValue }
        let name = "setMCLLimit:error:"
        let method = try checked(name, result: ["B", "c"], arguments: ["@", ":", "C", "^@"])
        typealias Setter = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool
        var error: NSError?
        let success = unsafeBitCast(method_getImplementation(method), to: Setter.self)(client, NSSelectorFromString(name), UInt8(value), &error)
        if let error { throw error }
        guard success.boolValue else { throw BatteryPowerUIError.unconfirmed }
    }
    static func policyLimit() -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")),
              data.count < 1_048_576,
              let top = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archiveData = top["policies"] as? Data,
              let archive = try? PropertyListSerialization.propertyList(from: archiveData, format: nil) as? [String: Any],
              let objects = archive["$objects"] as? [Any] else { return nil }
        let limits = Set(objects.compactMap { ($0 as? [String: Any])?["soclimit"] as? Int })
        guard limits.count == 1, let limit = limits.first, (0...100).contains(limit) else { return nil }
        return limit
    }
}
