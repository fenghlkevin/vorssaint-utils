// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Browser scripting design adapted from LumaRing (MIT):
// https://github.com/potatoQi/LumaRing/blob/main/Sources/LumaRing/BrowserTabs.swift

import AppKit
import Carbon

struct RadialBrowserTab {
    let pid: pid_t
    let windowID: String
    let id: String
    let title: String
    var safariIndex: Int? = nil
    var safariURLs: [String] = []
    var safariTitles: [String] = []
}

enum RadialBrowserError: LocalizedError {
    case permission, changed, timeout, malformed, event(Int32)

    var errorDescription: String? {
        switch self {
        case .permission: return "请在系统设置的自动化权限中允许 Vorssaint 控制浏览器。"
        case .changed: return "标签页已关闭或移动，请重新打开环形切换器。"
        case .timeout: return "浏览器响应超时，请稍后重试。"
        case .malformed: return "无法识别浏览器返回的标签数据。"
        case .event(let code): return "浏览器标签操作失败（\(code)）。"
        }
    }
}

/// Chrome and Edge expose stable window/tab IDs through their native scripting
/// dictionaries. We re-resolve IDs before writes so a moved tab cannot make us
/// activate a different one by a stale index.
final class RadialBrowserEvents {
    private typealias Descriptor = NSAppleEventDescriptor
    private let pid: pid_t
    private let target: Descriptor
    private let deadline: TimeInterval
    private let isSafari: Bool

    static func supports(_ bundleID: String?) -> Bool {
        bundleID == "com.google.Chrome" || bundleID == "com.microsoft.edgemac" || bundleID == "com.apple.Safari"
    }

    init(pid: pid_t, budget: TimeInterval = 2) {
        self.pid = pid
        isSafari = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.Safari"
        target = Descriptor(processIdentifier: pid)
        deadline = ProcessInfo.processInfo.systemUptime + budget
    }

    static func permission(pid: pid_t, ask: Bool) -> OSStatus {
        let target = Descriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc,
                                                     typeWildCard, typeWildCard, ask)
    }

    private static func code(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func object(_ kind: String,
                               container: Descriptor = .null(),
                               index: Int? = nil,
                               id: String? = nil, numericID: Bool = false) -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: code(kind)),
                             forKeyword: UInt32(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: UInt32(keyAEContainer))
        let form: UInt32 = id == nil ? UInt32(formAbsolutePosition) : UInt32(formUniqueID)
        record.setDescriptor(Descriptor(enumCode: form), forKeyword: UInt32(keyAEKeyForm))
        if let id {
            record.setDescriptor(numericID ? Descriptor(int32: Int32(id) ?? 0) : Descriptor(string: id), forKeyword: UInt32(keyAEKeyData))
        } else if let index {
            record.setDescriptor(Descriptor(int32: Int32(index)), forKeyword: UInt32(keyAEKeyData))
        } else {
            let all = Descriptor(enumCode: UInt32(kAEAll))
            record.setDescriptor(Descriptor(descriptorType: UInt32(typeAbsoluteOrdinal),
                                            data: all.data)!, forKeyword: UInt32(keyAEKeyData))
        }
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }

    private static func property(_ name: String, of object: Descriptor) -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: code("prop")),
                             forKeyword: UInt32(keyAEDesiredClass))
        record.setDescriptor(object, forKeyword: UInt32(keyAEContainer))
        record.setDescriptor(Descriptor(enumCode: UInt32(formPropertyID)),
                             forKeyword: UInt32(keyAEKeyForm))
        record.setDescriptor(Descriptor(typeCode: code(name)),
                             forKeyword: UInt32(keyAEKeyData))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }

    private func event(_ operation: String,
                       object: Descriptor?,
                       value: Descriptor? = nil,
                       parameters: [String: Descriptor] = [:]) throws -> Descriptor {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw RadialBrowserError.timeout }
        let request = Descriptor(eventClass: Self.code("core"),
                                 eventID: Self.code(operation),
                                 targetDescriptor: target,
                                 returnID: AEReturnID(kAutoGenerateReturnID),
                                 transactionID: AETransactionID(kAnyTransactionID))
        if let object { request.setParam(object, forKeyword: keyDirectObject) }
        if let value { request.setParam(value, forKeyword: Self.code("data")) }
        for (key, parameter) in parameters {
            request.setParam(parameter, forKeyword: Self.code(key))
        }
        let reply: Descriptor
        do {
            reply = try request.sendEvent(options: [.waitForReply, .neverInteract],
                                          timeout: min(remaining, 0.7))
        } catch {
            let code = Int32((error as NSError).code)
            if code == -1743 || code == -1744 { throw RadialBrowserError.permission }
            if code == -1712 { throw RadialBrowserError.timeout }
            throw RadialBrowserError.event(code)
        }
        let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
        guard code == 0 else {
            if code == -1743 || code == -1744 { throw RadialBrowserError.permission }
            throw RadialBrowserError.event(code)
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }

    private func get(_ property: String, of object: Descriptor) throws -> Descriptor {
        try event("getd", object: Self.property(property, of: object))
    }

    private func values(_ descriptor: Descriptor) throws -> [Descriptor] {
        guard descriptor.descriptorType == typeAEList else { throw RadialBrowserError.malformed }
        return (1...max(1, descriptor.numberOfItems)).compactMap {
            $0 <= descriptor.numberOfItems ? descriptor.atIndex($0) : nil
        }
    }

    private func ids(in windowID: String) throws -> [String] {
        let window = Self.object("cwin", id: windowID)
        do {
            return try values(get("ID  ", of: Self.object("CrTb", container: window)))
                .compactMap(\.stringValue)
        } catch RadialBrowserError.event(-1728) {
            // The source window can disappear when its final tab moves.
            return []
        }
    }

    func list() throws -> [RadialBrowserTab] {
        if isSafari { return try listSafari() }
        let windows = try values(get("ID  ", of: Self.object("cwin")))
            .compactMap(\.stringValue)
        var result: [RadialBrowserTab] = []
        for windowID in windows.prefix(32) {
            let window = Self.object("cwin", id: windowID)
            let tabs = Self.object("CrTb", container: window)
            let ids = try values(get("ID  ", of: tabs)).compactMap(\.stringValue)
            let titles = try values(get("pnam", of: tabs)).map { $0.stringValue ?? "" }
            guard ids.count == titles.count, try self.ids(in: windowID) == ids else {
                throw RadialBrowserError.changed
            }
            for index in ids.indices.prefix(max(0, 512 - result.count)) {
                result.append(RadialBrowserTab(pid: pid, windowID: windowID,
                                               id: ids[index],
                                               title: titles[index].isEmpty ? "未命名标签页" : titles[index]))
            }
            if result.count >= 512 { break }
        }
        return result
    }

    func activate(_ tab: RadialBrowserTab) throws {
        if isSafari {
            let (window, targetTab) = try safariTarget(tab)
            _ = try event("setd", object: Self.property("cTab", of: window), value: targetTab)
            _ = try event("setd", object: Self.property("pmnd", of: window), value: Descriptor(boolean: false))
            _ = try event("setd", object: Self.property("pidx", of: window), value: Descriptor(int32: 1))
            return
        }
        guard tab.pid == pid else { throw RadialBrowserError.changed }
        let windows = [tab.windowID] + (try values(get("ID  ", of: Self.object("cwin")))
            .compactMap(\.stringValue).filter { $0 != tab.windowID })
        for windowID in windows.prefix(32) {
            let currentIDs = try ids(in: windowID)
            guard let offset = currentIDs.firstIndex(of: tab.id) else { continue }
            let window = Self.object("cwin", id: windowID)
            let targetTab = Self.object("CrTb", container: window, index: offset + 1)
            guard try get("ID  ", of: targetTab).stringValue == tab.id else {
                throw RadialBrowserError.changed
            }
            _ = try event("setd", object: Self.property("acTI", of: window),
                          value: Descriptor(int32: Int32(offset + 1)))
            guard try get("ID  ", of: Self.property("acTa", of: window)).stringValue == tab.id else {
                throw RadialBrowserError.changed
            }
            if try get("pmnd", of: window).booleanValue {
                _ = try event("setd", object: Self.property("pmnd", of: window),
                              value: Descriptor(boolean: false))
            }
            _ = try event("setd", object: Self.property("pidx", of: window),
                          value: Descriptor(int32: 1))
            return
        }
        throw RadialBrowserError.changed
    }

    func close(_ tab: RadialBrowserTab) throws {
        if isSafari {
            let (_, targetTab) = try safariTarget(tab)
            _ = try event("clos", object: targetTab)
            return
        }
        guard tab.pid == pid else { throw RadialBrowserError.changed }
        let windows = [tab.windowID] + (try values(get("ID  ", of: Self.object("cwin")))
            .compactMap(\.stringValue).filter { $0 != tab.windowID })
        for windowID in windows.prefix(32) {
            guard try ids(in: windowID).contains(tab.id) else { continue }
            let window = Self.object("cwin", id: windowID)
            let targetTab = Self.object("CrTb", container: window, id: tab.id)
            guard try get("ID  ", of: targetTab).stringValue == tab.id else {
                throw RadialBrowserError.changed
            }
            _ = try event("clos", object: targetTab)
            return
        }
        throw RadialBrowserError.changed
    }

    private func listSafari() throws -> [RadialBrowserTab] {
        let windows = try values(get("ID  ", of: Self.object("cwin")))
        var result: [RadialBrowserTab] = []
        for identifier in windows.prefix(32) {
            let windowID = String(identifier.int32Value)
            let window = Self.object("cwin", id: windowID, numericID: true)
            let tabs = Self.object("bTab", container: window)
            let urls = try values(get("pURL", of: tabs)).map { $0.stringValue ?? "" }
            let titles = try values(get("pnam", of: tabs)).map { $0.stringValue ?? "" }
            guard urls.count == titles.count else { throw RadialBrowserError.changed }
            for index in urls.indices.prefix(max(0, 512 - result.count)) {
                result.append(RadialBrowserTab(pid: pid, windowID: windowID,
                    id: "safari:\(windowID):\(index)",
                    title: titles[index].isEmpty ? "未命名标签页" : titles[index],
                    safariIndex: index + 1, safariURLs: urls, safariTitles: titles))
            }
            if result.count >= 512 { break }
        }
        return result
    }

    /// Safari has no stable tab IDs. Refuse stale or ambiguous snapshots
    /// rather than operate on the new occupant of a reordered tab index.
    private func safariTarget(_ tab: RadialBrowserTab) throws -> (Descriptor, Descriptor) {
        guard tab.pid == pid, let index = tab.safariIndex,
              index > 0, index <= tab.safariURLs.count else { throw RadialBrowserError.changed }
        let window = Self.object("cwin", id: tab.windowID, numericID: true)
        let tabs = Self.object("bTab", container: window)
        let urls = try values(get("pURL", of: tabs)).map { $0.stringValue ?? "" }
        let titles = try values(get("pnam", of: tabs)).map { $0.stringValue ?? "" }
        guard urls == tab.safariURLs, titles == tab.safariTitles,
              urls.indices.filter({ urls[$0] == urls[index - 1] && titles[$0] == titles[index - 1] }).count == 1
        else { throw RadialBrowserError.changed }
        return (window, Self.object("bTab", container: window, index: index))
    }

    func newWindow() throws {
        if isSafari {
            _ = try event("crel", object: nil, parameters: ["kocl": Descriptor(typeCode: Self.code("docu"))])
            return
        }
        let properties = Descriptor.record()
        properties.setDescriptor(Descriptor(string: "normal"), forKeyword: Self.code("mode"))
        _ = try event("crel", object: nil, parameters: [
            "kocl": Descriptor(typeCode: Self.code("cwin")),
            "prdt": properties,
        ])
    }
}
