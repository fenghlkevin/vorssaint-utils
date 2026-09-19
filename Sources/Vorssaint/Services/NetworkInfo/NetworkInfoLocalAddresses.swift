// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation

struct NetworkInfoLocalAddress: Identifiable, Equatable, Hashable, Codable {
    let interface: String
    let ip: String
    var isTunnel: Bool = false
    var id: String { interface + ":" + ip }
}

enum NetworkInfoLocalAddresses {
    // Read active local and tunnel interfaces; exclude loopback and Apple peer-to-peer links.
    static func includes(interface: String, flags: UInt32) -> Bool {
        flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0
            && flags & UInt32(IFF_LOOPBACK) == 0
            // Hide virtual bridge adapters (Docker and desktop hypervisors);
            // they are implementation details rather than useful local IPs.
            && !["awdl", "llw", "gif", "stf", "bridge", "docker", "vmnet", "vmenet", "vboxnet"].contains { interface.hasPrefix($0) }
    }

    static func isTunnel(interface: String, flags: UInt32) -> Bool {
        flags & UInt32(IFF_POINTOPOINT) != 0
            || ["utun", "tun", "tap", "ipsec", "ppp"].contains { interface.hasPrefix($0) }
    }

    static func read() throws -> [NetworkInfoLocalAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw POSIXError(.EIO) }
        defer { if let first { freeifaddrs(first) } }
        var addresses = Set<NetworkInfoLocalAddress>()
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.ifa_name)
            guard includes(interface: name, flags: item.ifa_flags) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            guard ip != "0.0.0.0" else { continue }
            addresses.insert(NetworkInfoLocalAddress(interface: name, ip: ip, isTunnel: isTunnel(interface: name, flags: item.ifa_flags)))
        }
        return addresses.sorted { ($0.interface, $0.ip) < ($1.interface, $1.ip) }
    }
}
