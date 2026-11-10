import Foundation
import Network

// MARK: - 信任所有证书

final class ProxyTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let space = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: space))
    }
}

// MARK: - 本地 HTTP 反代：WKWebView → 127.0.0.1 → Xray http inbound → 机场节点

final class LocalProxy {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.yg.hub.localproxy", attributes: .concurrent)
    private let upstreamPort: UInt16
    private let defaultHost: String
    private let session: URLSession

    private(set) var port: UInt16?

    init(upstreamPort: UInt16, defaultHost: String) {
        self.upstreamPort = upstreamPort
        self.defaultHost = defaultHost

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": NSNumber(value: upstreamPort),
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": NSNumber(value: upstreamPort)
        ] as [AnyHashable: Any]
        cfg.timeoutIntervalForRequest = 40
        cfg.timeoutIntervalForResource = 180
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg, delegate: ProxyTrust(), delegateQueue: nil)
    }

    // MARK: 生命周期

    func start(completion: @escaping (Bool) -> Void) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: .any)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.port = l.port?.rawValue
                    DispatchQueue.main.async { completion(self.port != nil) }
                case .failed, .cancelled:
                    DispatchQueue.main.async { completion(false) }
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            DispatchQueue.main.async { completion(false) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        session.invalidateAndCancel()
        port = nil
    }

    // MARK: 收包

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.read(conn, buffer: Data())
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buf = buffer
            if let d = data, !d.isEmpty { buf.append(d) }

            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: 0..<range.lowerBound)
                let body = buf.subdata(in: range.upperBound..<buf.count)
                self.route(conn, head: head, body: body)
                return
            }

            if isComplete || error != nil || buf.count > 262_144 {
                conn.cancel()
                return
            }
            self.read(conn, buffer: buf)
        }
    }

    // MARK: 路由

    private func route(_ conn: NWConnection, head: Data, body: Data) {
        guard let text = String(data: head, encoding: .utf8) else {
            reply(conn, status: 400, text: "bad request")
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else {
            reply(conn, status: 400, text: "bad request")
            return
        }
        let headParts = first.components(separatedBy: " ")
        guard headParts.count >= 2 else {
            reply(conn, status: 400, text: "bad request")
            return
        }

        let method = headParts[0].uppercased()
        let rawPath = headParts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if headers[k] == nil { headers[k] = v }
        }

        var host = defaultHost
        var pathQuery = rawPath

        if rawPath.hasPrefix("/__x/") {
            let after = String(rawPath.dropFirst(5))
            if let slash = after.firstIndex(of: "/") {
                host = String(after[..<slash])
                pathQuery = String(after[slash...])
            } else {
                host = after
                pathQuery = "/"
            }
        }

        guard !host.isEmpty,
              let url = URL(string: "https://\(host)\(pathQuery)") else {
            reply(conn, status: 400, text: "bad target")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if method == "POST" || method == "PUT" || method == "PATCH" {
            req.httpBody = body
            if let ct = headers["content-type"] {
                req.setValue(ct, forHTTPHeaderField: "Content-Type")
            }
        }
        if let ua = headers["user-agent"], !ua.isEmpty {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        for key in ["accept", "accept-language", "referer", "cookie", "range", "if-none-match", "if-modified-since"] {
            if let v = headers[key], !v.isEmpty {
                req.setValue(v, forHTTPHeaderField: key)
            }
        }
        if headers["referer"] == nil {
            req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }

        let task = session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self else { return }
            self.finish(conn, method: method, host: host, data: data, response: resp)
        }
        task.resume()
    }

    // MARK: 回写

    private func finish(_ conn: NWConnection, method: String, host: String, data: Data?, response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else {
            reply(conn, status: 502, text: "upstream failed")
            return
        }

        var payload = data ?? Data()
        let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")

        if ctype.lowercased().contains("text/html") {
            payload = LocalProxy.rewriteHTML(payload, host: host)
        } else if ctype.lowercased().contains("mpegurl") || ctype.lowercased().contains("vnd.apple") {
            payload = LocalProxy.rewritePlaylist(payload)
        }

        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        head += "Content-Type: \(ctype)\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n"
        if let loc = http.value(forHTTPHeaderField: "Location") {
            head += "Location: \(LocalProxy.rewriteLocation(loc, host: host))\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        if method != "HEAD" { out.append(payload) }

        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func reply(_ conn: NWConnection, status: Int, text: String) {
        let body = Data("{\"error\":\"\(text)\"}".utf8)
        var head = "HTTP/1.1 \(status) Error\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: 内容改写

    private static let absPattern = #"https?://([a-zA-Z0-9.\-]+(?::[0-9]+)?)(/[^"'\s\\)<>]*)?"#

    static func rewriteAbsolute(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: absPattern, options: [.caseInsensitive]) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out = s
        for m in matches.reversed() {
            guard m.range.location != NSNotFound,
                  let full = Range(m.range, in: out) else { continue }
            let host = ns.substring(with: m.range(at: 1))
            if host.hasPrefix("127.0.0.1") { continue }
            let path = m.range(at: 2).location == NSNotFound ? "/" : ns.substring(with: m.range(at: 2))
            out.replaceSubrange(full, with: "/__x/\(host)\(path)")
        }
        return out
    }

    static func rewriteHTML(_ data: Data, host: String) -> Data {
        guard var s = String(data: data, encoding: .utf8) else { return data }
        s = rewriteAbsolute(s)

        let base = "<base href=\"/\">"
        if let h = s.range(of: "<head", options: .caseInsensitive),
           let gt = s[h.lowerBound...].firstIndex(of: ">") {
            s.insert(contentsOf: base, at: s.index(after: gt))
        }

        // 站内相对协议链接 //cdn.xxx → 也转走
        if let re = try? NSRegularExpression(pattern: #"(?<=["'\(])//([a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})(/[^"'\s]*)"#) {
            let ns = s as NSString
            let ms = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            var out = s
            for m in ms.reversed() {
                guard let full = Range(m.range, in: out) else { continue }
                let h = ns.substring(with: m.range(at: 1))
                let p = ns.substring(with: m.range(at: 2))
                out.replaceSubrange(full, with: "/__x/\(h)\(p)")
            }
            s = out
        }
        return Data(s.utf8)
    }

    static func rewritePlaylist(_ data: Data) -> Data {
        guard var s = String(data: data, encoding: .utf8) else { return data }
        s = rewriteAbsolute(s)
        return Data(s.utf8)
    }

    static func rewriteLocation(_ loc: String, host: String) -> String {
        if loc.hasPrefix("http://") || loc.hasPrefix("https://") {
            return rewriteAbsolute(loc)
        }
        if loc.hasPrefix("/") { return loc }
        return "/\(loc)"
    }
}
