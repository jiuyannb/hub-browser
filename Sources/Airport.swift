import Foundation
import Network

// MARK: - 节点

struct ProxyNode: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var type: String
    var host: String
    var port: Int
    var raw: String
    var latency: Int?
}

// MARK: - 订阅条目

struct SubEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var updated: Date = Date()
    var count: Int = 0
}

// MARK: - 订阅解析（vmess / vless / trojan / ss / hysteria2 / http）

enum SubParser {

    static func parse(_ text: String) -> [ProxyNode] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clash / Clash Meta 配置（机场订阅最常见的格式）
        if t.contains("proxies:") && t.contains("server:") {
            let clash = parseClash(t)
            if !clash.isEmpty { return clash }
        }

        let body = unwrap(t)
        var out: [ProxyNode] = []
        for line in body.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if s.hasPrefix("#") || s.hasPrefix("//") || s.hasPrefix(";") { continue }
            if let n = parseLine(s) { out.append(n) }
        }
        return out
    }

    // MARK: Clash YAML

    static func parseClash(_ text: String) -> [ProxyNode] {
        var out: [ProxyNode] = []
        var cur: [String: String] = [:]
        var inProxy = false

        func flush() {
            defer { cur = [:] }
            guard let server = cur["server"],
                  let portS = cur["port"],
                  let port = Int(portS.trimmingCharacters(in: .whitespaces)),
                  port > 0, !server.isEmpty else { return }
            let type = (cur["type"] ?? "vmess").lowercased()
            let name = cur["name"]?.isEmpty == false ? cur["name"]! : server
            let raw = buildVmessLink(type: type, d: cur) ?? "\(type)://\(server):\(port)#\(name)"
            out.append(ProxyNode(name: name, type: type, host: server, port: port, raw: raw))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("- {") || line.hasPrefix("-{") {
                let d = clashFlow(line)
                if d["server"] != nil {
                    cur = d
                    flush()
                    inProxy = false
                }
                continue
            }

            if line.hasPrefix("- name:") {
                flush()
                inProxy = true
                cur["name"] = unquote(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                continue
            }

            if inProxy, let colon = line.firstIndex(of: ":") {
                let k = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if k.isEmpty || k.contains(" ") { continue }
                if !v.hasPrefix("{") {
                    cur[k] = unquote(v)
                }
            }

            if inProxy, line.hasPrefix("- ") && !line.hasPrefix("- name:") {
                // 新的列表项但不是 name 开头，忽略
            }
        }
        flush()
        return out
    }

    static func clashFlow(_ line: String) -> [String: String] {
        var d: [String: String] = [:]
        let keys = ["name", "type", "server", "port", "uuid", "password", "cipher", "sni", "servername", "network"]
        for k in keys {
            if let v = regexValue(line, k) { d[k] = v }
        }
        if let h = regexValue(line, "Host") { d["Host"] = h }
        if let p = regexValue(line, "path") { d["path"] = p }
        return d
    }

    static func regexValue(_ s: String, _ key: String) -> String? {
        let pat = "(?:^|[\\s,{])" + NSRegularExpression.escapedPattern(for: key) + ":\\s*'?([^',}\\n]+)'?"
        guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        let v = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func unquote(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if (v.hasPrefix("'") && v.hasSuffix("'")) || (v.hasPrefix("\"") && v.hasSuffix("\"")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    /// 把 Clash 节点还原成标准 vmess:// 链接（base64 JSON），方便分享/导入
    static func buildVmessLink(type: String, d: [String: String]) -> String? {
        guard type == "vmess", let add = d["server"], let port = d["port"], let id = d["uuid"] else { return nil }
        let obj: [String: Any] = [
            "v": "2",
            "ps": d["name"] ?? add,
            "add": add,
            "port": port,
            "id": id,
            "aid": d["alterId"] ?? "0",
            "scy": d["cipher"] ?? "auto",
            "net": d["network"] ?? "tcp",
            "type": "none",
            "host": d["Host"] ?? "",
            "path": d["path"] ?? "",
            "tls": d["tls"] ?? "",
            "sni": d["servername"] ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return "vmess://" + data.base64EncodedString()
    }

    static func unwrap(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://") { return t }
        var s = t
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        if let d = Data(base64Encoded: s),
           let str = String(data: d, encoding: .utf8),
           str.contains("://") {
            return str
        }
        return t
    }

    static func parseLine(_ s: String) -> ProxyNode? {
        guard let scheme = s.split(separator: ":").first?.lowercased() else { return nil }
        switch scheme {
        case "vmess":
            return vmess(s)
        case "ss":
            return shadowsocks(s)
        case "trojan":
            return generic(s, type: "trojan")
        case "vless":
            return generic(s, type: "vless")
        case "hysteria", "hy", "hysteria2", "hy2":
            return generic(s, type: "hy2")
        case "tuic":
            return generic(s, type: "tuic")
        case "http", "https":
            return generic(s, type: "http")
        case "socks", "socks5":
            return generic(s, type: "socks")
        default:
            return nil
        }
    }

    // MARK: 各协议

    static func vmess(_ s: String) -> ProxyNode? {
        guard let r = s.range(of: "://") else { return nil }
        var body = String(s[r.upperBound...])
        if let h = body.firstIndex(of: "#") { body = String(body[body.startIndex..<h]) }

        // query 段不属于 base64，先剥离（形如 ?path=/&remarks=xxx&obfs=websocket）
        var query = ""
        if let q = body.firstIndex(of: "?") {
            query = String(body[body.index(after: q)...])
            body = String(body[body.startIndex..<q])
        }

        var b = body
        while b.count % 4 != 0 { b.append("=") }
        guard let d = Data(base64Encoded: b) else { return nil }
        let decoded = String(data: d, encoding: .utf8) ?? ""

        let f = frag(s)
        let fallbackName = f.isEmpty ? (queryValue(query, "remarks") ?? "") : f

        // A) 标准 v2rayN：base64({"v":"2","ps":...,"add":...,"port":...})
        if decoded.contains("{"),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            let ps = (obj["ps"] as? String) ?? ""
            let name = ps.isEmpty ? fallbackName : ps
            let host = (obj["add"] as? String) ?? ""
            var port = 0
            if let pi = obj["port"] as? Int { port = pi }
            else if let ps2 = obj["port"] as? String { port = Int(ps2) ?? 0 }
            if !host.isEmpty, port > 0 {
                return ProxyNode(name: name.isEmpty ? host : name, type: "vmess", host: host, port: port, raw: s)
            }
        }

        // B) SIP002 变体：base64("auto:uuid@host:port")
        if let at = decoded.lastIndex(of: "@") {
            var hp = String(decoded[decoded.index(after: at)...])
            if let q = hp.firstIndex(of: "?") { hp = String(hp[hp.startIndex..<q]) }
            if let (h, p) = hostPort(hp) {
                return ProxyNode(name: fallbackName.isEmpty ? h : fallbackName, type: "vmess", host: h, port: p, raw: s)
            }
        }
        return nil
    }

    static func queryValue(_ q: String, _ key: String) -> String? {
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, String(kv[0]) == key {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }

    static func shadowsocks(_ s: String) -> ProxyNode? {
        guard let r = s.range(of: "://") else { return nil }
        var body = String(s[r.upperBound...])
        let name = frag(s)
        if let h = body.firstIndex(of: "#") { body = String(body[body.startIndex..<h]) }
        if let q = body.firstIndex(of: "?") { body = String(body[body.startIndex..<q]) }
        if let at = body.lastIndex(of: "@") {
            let hp = String(body[body.index(after: at)...])
            if let (h, p) = hostPort(hp) {
                return ProxyNode(name: name.isEmpty ? h : name, type: "ss", host: h, port: p, raw: s)
            }
        }
        var b = body
        while b.count % 4 != 0 { b.append("=") }
        if let d = Data(base64Encoded: b),
           let dec = String(data: d, encoding: .utf8),
           let (h, p) = hostPort(dec) {
            return ProxyNode(name: name.isEmpty ? h : name, type: "ss", host: h, port: p, raw: s)
        }
        return nil
    }

    static func generic(_ s: String, type: String) -> ProxyNode? {
        guard let r = s.range(of: "://") else { return nil }
        let rest = String(s[r.upperBound...])
        guard let (h, p) = hostPort(rest) else { return nil }
        let n = frag(s)
        return ProxyNode(name: n.isEmpty ? h : n, type: type, host: h, port: p, raw: s)
    }

    // MARK: 工具

    static func frag(_ s: String) -> String {
        guard let i = s.firstIndex(of: "#") else { return "" }
        let f = String(s[s.index(after: i)...])
        return f.removingPercentEncoding ?? f
    }

    static func hostPort(_ rest: String) -> (String, Int)? {
        var r = rest
        if let q = r.firstIndex(of: "?") { r = String(r[r.startIndex..<q]) }
        if let sl = r.firstIndex(of: "/") { r = String(r[r.startIndex..<sl]) }
        if r.hasPrefix("[") {
            guard let close = r.firstIndex(of: "]") else { return nil }
            let h = String(r[r.index(after: r.startIndex)..<close])
            var tail = String(r[r.index(after: close)...])
            if tail.hasPrefix(":") { tail = String(tail.dropFirst()) }
            guard let p = Int(tail), !h.isEmpty else { return nil }
            return (h, p)
        }
        if let at = r.lastIndex(of: "@") { r = String(r[r.index(after: at)...]) }
        let parts = r.split(separator: ":")
        guard parts.count >= 2, let p = Int(parts[1]) else { return nil }
        return (String(parts[0]), p)
    }
}

// MARK: - 允许自签证书的会话（机场订阅常是 IP + 自签 HTTPS）

final class TrustAllSession: NSObject, URLSessionDelegate {

    static let shared = TrustAllSession()

    lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - TCP 延迟测试

final class Latency {

    static func test(host: String, port: Int, timeout: Double = 3.0, completion: @escaping (Int?) -> Void) {
        guard port > 0, port < 65536 else { completion(nil); return }
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { completion(nil); return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let start = Date()
        var done = false

        func finish(_ ms: Int?) {
            if done { return }
            done = true
            conn.stateUpdateHandler = nil
            conn.cancel()
            DispatchQueue.main.async { completion(ms) }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(Int(Date().timeIntervalSince(start) * 1000))
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
}
