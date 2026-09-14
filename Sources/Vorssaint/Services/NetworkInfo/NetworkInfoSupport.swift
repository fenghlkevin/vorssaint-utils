// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum NetworkInfoRoute: String, CaseIterable, Identifiable, Sendable, Codable {
    case domestic, international
    var id: String { rawValue }
    var probes: [NetworkInfoProbe] {
        switch self {
        case .domestic:
            return [NetworkInfoProbe(url: URL(string: "https://ipv4.ddnspod.com")!, format: .plain),
                    NetworkInfoProbe(url: URL(string: "https://myip.ipip.net")!, format: .ipip)]
        case .international:
            return [NetworkInfoProbe(url: URL(string: "https://api.ipify.org")!, format: .plain)]
        }
    }
}

struct NetworkInfoProbe: Sendable {
    enum Format: Sendable { case plain, ipip }
    let url: URL
    let format: Format

    func parse(_ data: Data) throws -> String {
        switch format {
        case .plain: return try NetworkInfoSupport.parseIPv4(data)
        case .ipip:
            // IPIP's public endpoint is text, not JSON. Only accept its labelled IP field.
            guard data.count <= 4096, let raw = String(data: data, encoding: .utf8),
                  raw.hasPrefix("当前 IP："),
                  let field = raw.dropFirst("当前 IP：".count).split(whereSeparator: { $0.isWhitespace }).first else {
                throw NetworkInfoFailure.invalidResponse
            }
            return try NetworkInfoSupport.parseIPv4(Data(field.utf8))
        }
    }
}

enum NetworkInfoFailure: String, Error, Equatable, Sendable, Codable {
    case invalidResponse, unavailable, rateLimited, timedOut, secureConnection
}

struct NetworkIPDetails: Equatable, Sendable, Codable {
    let country: String?
    let region: String?
    let city: String?
    let isp: String?
    let organization: String?
    let asn: UInt32?

    var location: String? {
        var seen = Set<String>()
        let parts = [country, region, city].compactMap { $0 }.filter { seen.insert($0).inserted }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var operatorName: String? { isp ?? organization }
    var asnDescription: String? {
        guard let asn else { return organization }
        return (["AS\(asn)"] + [organization].compactMap { $0 }).joined(separator: " · ")
    }
}

struct NetworkInfoResult: Equatable, Sendable, Codable {
    let ip: String
    let checkedAt: Date
    var details: NetworkIPDetails?
    var lookupFailure: NetworkInfoFailure?
    var probeHost: String?
}

struct NetworkInfoState: Equatable, Sendable {
    var result: NetworkInfoResult?
    var isLoading = false
    var failure: NetworkInfoFailure?
    var isStale = false
    var attemptedAt: Date?

    func needsRefresh(now: Date) -> Bool {
        guard !isLoading else { return false }
        // Failed requests back off on reopen; an explicit refresh can retry.
        if failure != nil || result?.lookupFailure != nil {
            return attemptedAt.map { now.timeIntervalSince($0) >= 30 } ?? true
        }
        if isStale { return true }
        return result.map { now.timeIntervalSince($0.checkedAt) >= 300 } ?? true
    }
}

enum NetworkInfoSupport {
    /// The probes are IPv4-only. Reject HTML, IPv6 and non-public addresses.
    static func parseIPv4(_ data: Data) throws -> String {
        guard data.count <= 128, let raw = String(data: data, encoding: .utf8) else {
            throw NetworkInfoFailure.invalidResponse
        }
        let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw NetworkInfoFailure.invalidResponse }
        let octets = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0" else { return nil }
            return UInt8(part)
        }
        guard octets.count == 4 else { throw NetworkInfoFailure.invalidResponse }
        let a = octets[0], b = octets[1]
        guard a > 0, a < 224, a != 10, a != 127,
              !(a == 100 && (64...127).contains(b)),
              !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
              !(a == 192 && b == 168), !(a == 198 && (18...19).contains(b)) else {
            throw NetworkInfoFailure.invalidResponse
        }
        return ip
    }

    static func lookupURL(ip: String) throws -> URL {
        let validated = try parseIPv4(Data(ip.utf8))
        var url = URLComponents(string: "https://ipwho.is/\(validated)")!
        url.queryItems = [URLQueryItem(name: "fields", value: "success,ip,country,region,city,connection")]
        return url.url!
    }

    static func decodeDetails(_ data: Data, expectedIP: String) throws -> NetworkIPDetails {
        struct Response: Decodable {
            struct Connection: Decodable {
                let isp: String?
                let org: String?
                let asn: UInt32?
            }
            let success: Bool
            let ip: String?
            let country: String?
            let region: String?
            let city: String?
            let connection: Connection?
        }
        guard data.count <= 65_536,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.success, response.ip == expectedIP else {
            throw NetworkInfoFailure.invalidResponse
        }
        func clean(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : String(text.prefix(200))
        }
        return NetworkIPDetails(country: clean(response.country), region: clean(response.region),
                                city: clean(response.city), isp: clean(response.connection?.isp),
                                organization: clean(response.connection?.org), asn: response.connection?.asn)
    }

    static func failure(_ error: Error) -> NetworkInfoFailure {
        if let known = error as? NetworkInfoFailure { return known }
        if let code = (error as? URLError)?.code {
            if code == .timedOut { return .timedOut }
            if [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains(code) {
                return .secureConnection
            }
        }
        return .unavailable
    }
}

/// No shared cookies, disk cache, credentials or custom proxy override.
struct NetworkInfoClient {
    let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func read(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NetworkInfoFailure.invalidResponse }
        if http.statusCode == 429 { throw NetworkInfoFailure.rateLimited }
        guard (200...299).contains(http.statusCode) else { throw NetworkInfoFailure.unavailable }
        guard data.count <= 65_536 else { throw NetworkInfoFailure.invalidResponse }
        return data
    }

    func probe(_ route: NetworkInfoRoute) async throws -> NetworkInfoResult {
        var lastError: Error = NetworkInfoFailure.unavailable
        for probe in route.probes {
            try Task.checkCancellation()
            do {
                let ip = try probe.parse(try await read(probe.url))
                return NetworkInfoResult(ip: ip, checkedAt: Date(), probeHost: probe.url.host)
            } catch {
                // Cancellation belongs to the caller, never a reason to contact another provider.
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    func lookup(ip: String) async throws -> NetworkIPDetails {
        try NetworkInfoSupport.decodeDetails(try await read(NetworkInfoSupport.lookupURL(ip: ip)), expectedIP: ip)
    }
}
