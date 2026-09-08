// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

struct CommandBarPortSocket: Equatable {
    let pid: pid_t
    let name: String
    let transport: String
    let address: String
}

struct CommandBarPortProcess: Equatable {
    let pid: pid_t
    let name: String
    let path: String
    let startedAt: UInt64?
    let sockets: [CommandBarPortSocket]

    var isProtected: Bool {
        startedAt == nil || KillProcessSupport.isProtected(pid: pid, name: name, path: path)
    }
}

enum CommandBarPortError: Error, Equatable {
    case scanFailed, timedOut, protectedProcess, staleProcess, permissionDenied, killFailed
}

enum CommandBarPortSupport {
    enum Query: Equatable { case unrelated, needsPort, invalid, port(Int) }

    static func query(_ text: String) -> Query {
        let pieces = text.split(whereSeparator: \.isWhitespace)
        guard let verb = pieces.first, ["port", "端口"].contains(verb.lowercased()) else { return .unrelated }
        guard pieces.count > 1 else { return .needsPort }
        guard pieces.count == 2, pieces[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(pieces[1]), (1...65535).contains(port) else { return .invalid }
        return .port(port)
    }

    /// lsof field output avoids parsing whitespace in process names and IPv6.
    /// Only the local endpoint counts: a remote :8080 is not a local owner.
    static func parse(_ text: String, port: Int) -> [CommandBarPortSocket] {
        var pid: pid_t?, name = "", transport = ""
        var rows: [CommandBarPortSocket] = []
        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": pid = pid_t(value); name = ""; transport = ""
            case "c": name = value
            case "f": transport = ""
            case "P": transport = value
            case "n":
                guard let pid, pid > 0, ["TCP", "UDP"].contains(transport) else { continue }
                let local = value.components(separatedBy: "->")[0]
                guard local.split(separator: ":").last.flatMap({ Int($0) }) == port else { continue }
                let row = CommandBarPortSocket(pid: pid, name: name, transport: transport, address: local)
                if !rows.contains(row) { rows.append(row) }
            default: break
            }
        }
        return rows
    }

    static func scan(port: Int) throws -> [CommandBarPortProcess] {
        guard (1...65535).contains(port) else { throw CommandBarPortError.scanFailed }
        var sockets: [CommandBarPortSocket] = []
        for transport in ["TCP", "UDP"] {
            var args = ["-nP", "-a", "-i\(transport):\(port)", "-FpcfPn"]
            if transport == "TCP" { args.append(contentsOf: ["-sTCP:LISTEN"]) }
            let result = BoundedProcessRunner.run("/usr/sbin/lsof", args, timeout: 3, maxOutputBytes: 256 * 1024)
            if result.timedOut { throw CommandBarPortError.timedOut }
            let output = String(decoding: result.output, as: UTF8.self)
            guard result.output.count < 256 * 1024,
                  result.status == 0 || (result.status == 1 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                  !output.contains("lsof:") else { throw CommandBarPortError.scanFailed }
            sockets.append(contentsOf: parse(output, port: port))
        }
        return Dictionary(grouping: sockets, by: \.pid).map { pid, sockets in
            let identity = identity(pid: pid)
            return CommandBarPortProcess(pid: pid, name: sockets[0].name,
                                         path: identity?.path ?? "", startedAt: identity?.start,
                                         sockets: sockets)
        }.sorted { $0.pid < $1.pid }
    }

    private static func identity(pid: pid_t) -> (start: UInt64, path: String)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return (info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec, String(cString: buffer))
    }

    static func sameIdentity(_ original: CommandBarPortProcess, _ current: CommandBarPortProcess) -> Bool {
        original.pid == current.pid && original.startedAt != nil
            && original.startedAt == current.startedAt && original.path == current.path
    }

    /// Recheck both port ownership and process birth time after confirmation.
    static func forceKill(_ target: CommandBarPortProcess, port: Int) throws {
        guard !target.isProtected else { throw CommandBarPortError.protectedProcess }
        guard let current = try scan(port: port).first(where: { sameIdentity(target, $0) }),
              !current.isProtected,
              let latest = identity(pid: target.pid), latest.start == target.startedAt,
              latest.path == target.path else { throw CommandBarPortError.staleProcess }
        guard Darwin.kill(target.pid, SIGKILL) == 0 else {
            switch errno {
            case EPERM: throw CommandBarPortError.permissionDenied
            case ESRCH: throw CommandBarPortError.staleProcess
            default: throw CommandBarPortError.killFailed
            }
        }
    }
}
