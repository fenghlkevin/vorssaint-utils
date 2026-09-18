// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
final class ProxyStubProtocol: URLProtocol {
    static var observed: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.observed = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct ProxyAPITests {
    static func main() async throws {
        let api = ProxyAPI(port: 29090, secret: "fixture-token", protocolClasses: [ProxyStubProtocol.self])
        _ = try await api.request(["proxies", "HK / #1?中"], method: "PUT", body: ["name": "DIRECT"])
        guard let request = ProxyStubProtocol.observed,
              request.url?.absoluteString == "http://127.0.0.1:29090/proxies/HK%20%2F%20%231%3F%E4%B8%AD",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
              request.httpMethod == "PUT" else { fatalError("API segment encoding/auth regression") }
        print("Proxy API path encoding and authentication passed")
    }
}
