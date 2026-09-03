// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import JavaScriptCore

/// Runs before application/defaults initialization, with no AppKit UI or native JS object exports.
enum BobPluginWorker {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--translation-plugin-worker") else { return }
        do {
            let input = try FileHandle.standardInput.read(upToCount: 10_000_001) ?? Data()
            guard input.count <= 10_000_000 else { throw TranslationFailure.invalidPackage }
            // Pipe reads can be short; continue until EOF, still bounded.
            var body = input
            while let next = try FileHandle.standardInput.read(upToCount: 16_384), !next.isEmpty {
                body.append(next)
                guard body.count <= 10_000_000 else { throw TranslationFailure.invalidPackage }
            }
            let request = try JSONDecoder().decode(BobTranslationRequest.self, from: body)
            let runtime = try BobJavaScriptRuntime(request: request)
            let result = runtime.run()
            try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result))
            exit(0)
        } catch {
            let result = ["error": ["message": "Plugin worker: \((error as? TranslationFailure)?.rawValue ?? "invalidPackage")"]]
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                try? FileHandle.standardOutput.write(contentsOf: data)
            }
            exit(0)
        }
    }
}

private final class BobJavaScriptRuntime {
    private let request: BobTranslationRequest
    private let context: JSContext
    private var result: [String: Any]?
    private var requests: [UUID: BobHTTPTask] = [:]
    private var requestCount = 0

    init(request: BobTranslationRequest) throws {
        try request.package.validate()
        guard request.text.count <= 20_000, let context = JSContext() else { throw TranslationFailure.invalidPackage }
        self.request = request
        self.context = context
    }

    func run() -> [String: Any] {
        context.exceptionHandler = { [weak self] _, _ in
            // JS exceptions may contain tokens or source text; never echo them to logs or UI.
            if self?.result == nil {
                self?.result = ["error": ["message": "Plugin JavaScript exception / unsupported API"]]
            }
        }
        let complete: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard self?.result == nil else { return }
            self?.result = value.toDictionary() as? [String: Any] ?? ["error": ["message": "invalidResult"]]
        }
        let http: @convention(block) (JSValue, JSValue) -> Void = { [weak self] options, callback in
            self?.send(options, callback: callback)
        }
        context.setObject(complete, forKeyedSubscript: "__complete" as NSString)
        context.setObject(http, forKeyedSubscript: "__http" as NSString)
        context.setObject(request.package.files, forKeyedSubscript: "__files" as NSString)
        context.setObject(request.options, forKeyedSubscript: "$option" as NSString)
        context.setObject(["appName": "Vorssaint", "host": "Vorssaint", "compatibility": "text-v1",
                           "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"],
                          forKeyedSubscript: "$env" as NSString)
        if let data = try? JSONEncoder().encode(request.package.manifest),
           let info = try? JSONSerialization.jsonObject(with: data) {
            context.setObject(info, forKeyedSubscript: "$info" as NSString)
        }
        context.setObject(["text": request.text, "originalText": request.text, "from": request.from,
                           "to": request.to, "detectFrom": request.detectFrom, "detectTo": request.to],
                          forKeyedSubscript: "__query" as NSString)
        context.evaluateScript(Self.bootstrap)
        if result == nil { context.evaluateScript(Self.invoke) }
        let deadline = Date().addingTimeInterval(35)
        while result == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        requests.values.forEach { $0.cancel() }
        return result ?? ["error": ["message": "timeout"]]
    }

    private func send(_ value: JSValue, callback: JSValue) {
        func fail(_ message: String) { callback.call(withArguments: [["error": ["message": message]]]) }
        guard result == nil, requestCount < 8, requests.count < 4,
              let options = value.toDictionary() as? [String: Any],
              let address = options["url"] as? String, let url = URL(string: address),
              Self.allowed(url, hosts: request.hosts), options["files"] == nil else {
            fail("networkDenied: HTTPS + approved exact hostname required; files unsupported")
            return
        }
        requestCount += 1
        var http = URLRequest(url: url)
        http.httpMethod = (options["method"] as? String ?? "GET").uppercased()
        http.timeoutInterval = 25
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(http.httpMethod!) else {
            fail("unsupportedAPI: HTTP method"); return
        }
        if let headers = options["header"] as? [String: String] {
            for (key, value) in headers where !["host", "cookie", "content-length"].contains(key.lowercased()) {
                http.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body = options["body"] {
            if let string = body as? String { http.httpBody = Data(string.utf8) }
            else if let fields = body as? [String: Any] {
                if http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true {
                    guard let encoded = try? JSONSerialization.data(withJSONObject: fields) else {
                        fail("unsupportedAPI: JSON body"); return
                    }
                    http.httpBody = encoded
                } else {
                    var components = URLComponents()
                    components.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
                    let form = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
                    if ["GET", "HEAD"].contains(http.httpMethod!) {
                        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let query = [target?.percentEncodedQuery, form].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
                        target?.percentEncodedQuery = query
                        http.url = target?.url
                    } else {
                        http.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                        http.httpBody = Data(form.utf8)
                    }
                }
            } else { fail("unsupportedAPI: HTTP body"); return }
        }
        guard (http.httpBody?.count ?? 0) <= 1_000_000 else { fail("HTTP body too large"); return }
        let id = UUID()
        let task = BobHTTPTask()
        requests[id] = task
        task.start(http) { [weak self] data, response, error in
            guard let self, self.result == nil else { return }
            self.requests.removeValue(forKey: id)
            if error != nil { fail("network: request failed, redirected or exceeded 2 MB"); return }
            let parsed = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
                ?? (String(data: data, encoding: .utf8) ?? "")
            callback.call(withArguments: [["data": parsed,
                "response": ["statusCode": response?.statusCode ?? 0,
                             "headers": response?.allHeaderFields ?? [:],
                             "url": response?.url?.absoluteString ?? ""]]])
        }
    }

    static func allowed(_ url: URL, hosts: [String]) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && hosts.contains(url.host?.lowercased() ?? "")
    }

    private static let bootstrap = #"""
    const $log = {info(){}, warn(){}, error(){}, debug(){}};
    const console = $log;
    function unsupported(name) { throw new Error('unsupportedAPI: ' + name); }
    const $file = new Proxy({}, {get(){return () => unsupported('$file')}});
    const $websocket = new Proxy({}, {get(){return () => unsupported('$websocket')}});
    const $timer = new Proxy({}, {get(){return () => unsupported('$timer')}});
    const $data = new Proxy({}, {get(){return () => unsupported('$data')}});
    const $http = {
      request(o) {
        return new Promise((resolve, reject) => __http(o, r => {
          try { if (typeof o.handler === 'function') o.handler(r); }
          catch (_) { __complete({error:{message:'Plugin HTTP callback exception'}}); }
          resolve(r);
        }));
      },
      get(o) { return this.request(Object.assign({},o,{method:'GET'})); },
      post(o) { return this.request(Object.assign({},o,{method:'POST'})); },
      streamRequest() { return unsupported('$http.streamRequest'); }
    };
    const __cache = Object.create(null);
    function __load(name, parent) {
      if (typeof name !== 'string' || name.startsWith('/') || name.includes('\\')) return unsupported('require path');
      let parts = name.startsWith('.') ? parent.split('/').slice(0,-1) : [];
      for (const p of name.split('/')) {
        if (p === '..') { if (!parts.length) return unsupported('require traversal'); parts.pop(); }
        else if (p && p !== '.') parts.push(p);
      }
      let path = parts.join('/');
      if (!Object.prototype.hasOwnProperty.call(__files,path)) {
        if (Object.prototype.hasOwnProperty.call(__files,path+'.js')) path += '.js';
        else if (Object.prototype.hasOwnProperty.call(__files,path+'.json')) path += '.json';
        else return unsupported('require module');
      }
      if (__cache[path]) return __cache[path].exports;
      const module = {exports:{}}; __cache[path] = module;
      if (path.endsWith('.json')) module.exports = JSON.parse(__files[path]);
      else new Function('require','module','exports',__files[path])(n=>__load(n,path),module,module.exports);
      return module.exports;
    }
    const require = name => __load(name,'main.js');
    """#

    private static let invoke = #"""
    const __module = {exports:{}};
    const __main = new Function('require','module','exports', __files['main.js'] +
      '\n;return {translate:typeof translate === "function" ? translate : module.exports.translate,' +
      'languages:typeof supportLanguages === "function" ? supportLanguages : module.exports.supportLanguages};')
      (require,__module,__module.exports);
    if (typeof __main.translate !== 'function' || typeof __main.languages !== 'function') {
      __complete({error:{message:'Missing translate / supportLanguages'}});
    } else {
      const languages = __main.languages();
      if (!Array.isArray(languages) || !languages.includes(__query.to) ||
          !languages.includes(__query.from === 'auto' ? __query.detectFrom : __query.from)) {
        __complete({error:{message:'unsupportedLanguage'}});
      } else {
        __query.onCompletion = __complete;
        __query.onStream = () => unsupported('onStream');
        __query.cancelSignal = {isCancelled:false};
        const pending = __main.translate(__query, __complete);
        if (pending && typeof pending.catch === 'function')
          pending.catch(() => __complete({error:{message:'Plugin async exception / unsupported API'}}));
      }
    }
    """#
}

/// No cookies, cache, redirects or unbounded response buffers. Delegate callbacks stay on JS's main thread.
private final class BobHTTPTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var completion: ((Data, HTTPURLResponse?, Error?) -> Void)?
    func start(_ request: URLRequest, completion: @escaping (Data, HTTPURLResponse?, Error?) -> Void) {
        self.completion = completion
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        session.dataTask(with: request).resume()
    }
    func cancel() { session?.invalidateAndCancel(); session = nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        task.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(response.expectedContentLength > 2_000_000 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= 2_000_000 else { dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion?(data, response, error)
        completion = nil
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
