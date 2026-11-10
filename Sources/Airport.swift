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
        let body = unwrap(text)
        var out: [ProxyNode] = []
        for line in body.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if s.hasPrefix("#") || s.hasPrefix("//") || s.hasPrefix(";") { continue }
            if let n = parseLine(s) { out.append(n) }
        }
        return out
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
        var b = String(s[r.upperBound...])
        if let h = b.firstIndex(of: "#") { b = String(b[b.startIndex..<h]) }
        while b.count % 4 != 0 { b.append("=") }
        guard let d = Data(base64Encoded: b) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let name = (obj["ps"] as? String) ?? "vmess"
        let host = (obj["add"] as? String) ?? ""
        var port = 0
        if let pi = obj["port"] as? Int { port = pi }
        else if let ps = obj["port"] as? String { port = Int(ps) ?? 0 }
        guard !host.isEmpty, port > 0 else { return nil }
        return ProxyNode(name: name, type: "vmess", host: host, port: port, raw: s)
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
