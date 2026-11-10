import Foundation
import Network
import SwiftyXrayKit

// MARK: - vmess 链接解析

struct VmessLink {
    var host: String = ""
    var port: Int = 443
    var uuid: String = ""
    var aid: Int = 0
    var net: String = "ws"
    var path: String = "/"
    var hostHeader: String = ""
    var tls: Bool = false
    var sni: String = ""
    var cipher: String = "auto"

    static func parse(_ raw: String) -> VmessLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vmess://") else { return nil }
        let body = String(trimmed.dropFirst(8))
        if let link = parseStandard(body) { return link }
        return parseSIP002(body)
    }

    private static func parseStandard(_ body: String) -> VmessLink? {
        let b64 = body.components(separatedBy: "?").first ?? body
        guard let data = unbase64(b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func s(_ k: String) -> String {
            if let v = obj[k] as? String { return v }
            if let n = obj[k] as? NSNumber { return n.stringValue }
            return ""
        }

        var l = VmessLink()
        l.host = s("add")
        l.port = Int(s("port")) ?? 443
        l.uuid = s("id")
        l.aid = Int(s("aid")) ?? 0
        let net = s("net")
        if !net.isEmpty { l.net = net }
        let p = s("path")
        if !p.isEmpty { l.path = p }
        l.hostHeader = s("host")
        let t = s("tls").lowercased()
        l.tls = (t == "tls" || t == "true" || t == "1")
        l.sni = s("sni")
        let scy = s("scy")
        if !scy.isEmpty { l.cipher = scy }
        guard !l.host.isEmpty, !l.uuid.isEmpty else { return nil }
        return l
    }

    private static func parseSIP002(_ body: String) -> VmessLink? {
        let parts = body.components(separatedBy: "?")
        let main = parts.first ?? ""
        let query = parts.count > 1 ? parts[1] : ""
        guard let data = unbase64(main), let text = String(data: data, encoding: .utf8) else { return nil }
        let segs = text.components(separatedBy: "@")
        guard segs.count == 2 else { return nil }
        let left = segs[0].components(separatedBy: ":")
        guard left.count >= 2 else { return nil }
        let hp = segs[1].components(separatedBy: ":")
        guard hp.count == 2, let port = Int(hp[1]) else { return nil }

        var l = VmessLink()
        l.cipher = left[0]
        l.uuid = left[1]
        l.host = hp[0]
        l.port = port
        for kv in query.components(separatedBy: "&") {
            let p = kv.components(separatedBy: "=")
            guard p.count == 2 else { continue }
            let v = p[1].removingPercentEncoding ?? p[1]
            switch p[0].lowercased() {
            case "path": l.path = v
            case "obfs": if v.lowercased() == "websocket" { l.net = "ws" }
            case "tls": if v.lowercased() == "tls" { l.tls = true }
            default: break
            }
        }
        guard !l.host.isEmpty, !l.uuid.isEmpty else { return nil }
        return l
    }

    static func unbase64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = t.count % 4
        if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: t)
    }
}

// MARK: - 内置代理引擎（Xray 本地 http inbound + 本地反代）

final class ProxyEngine: ObservableObject {
    static let shared = ProxyEngine()

    enum State: Equatable {
        case idle, starting, running
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var activeName = ""
    @Published var xrayInfo = ""
    @Published var logLine = ""
    @Published private(set) var webPort: UInt16 = 0
    private(set) var webHost = ""

    let xrayPort: UInt16 = 10808
    private var proxy: LocalProxy?
    private let dataDir: URL
    private let configURL: URL

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private init() {
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dataDir = doc.appendingPathComponent("xray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        configURL = dataDir.appendingPathComponent("config.json")
        DispatchQueue.global().async { [weak self] in
            let v = (try? SwiftyXray.xrayVersion()) ?? ""
            DispatchQueue.main.async { self?.xrayInfo = v }
        }
    }

    // MARK: 启动

    func start(node: ProxyNode, completion: @escaping (Bool, String) -> Void) {
        stop()
        guard let link = VmessLink.parse(node.raw) else {
            state = .failed("只支持 vmess 节点")
            completion(false, "只支持 vmess 节点")
            return
        }
        state = .starting

        let cfg = ProxyEngine.makeConfig(link: link, inport: Int(xrayPort))
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) else {
            state = .failed("配置生成失败")
            completion(false, "配置生成失败")
            return
        }
        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            state = .failed("写配置失败")
            completion(false, "写配置失败")
            return
        }

        do {
            try SwiftyXray.run(dataDir: dataDir.path, configPath: configURL.path)
        } catch {
            state = .failed("Xray 启动失败：\(error.localizedDescription)")
            completion(false, "Xray 启动失败：\(error.localizedDescription)")
            return
        }

        activeName = node.name
        Prefs.saveSingle("proxyNode", node)
        state = .running
        completion(true, "已连接 \(node.name)")
    }

    func stop() {
        proxy?.stop()
        proxy = nil
        if isRunning {
            try? SwiftyXray.stop()
        }
        state = .idle
        activeName = ""
    }

    // MARK: 网页入口

    func open(site: Site, completion: @escaping (URL?) -> Void) {
        guard isRunning else {
            completion(nil)
            return
        }
        guard let host = URL(string: site.url)?.host, !host.isEmpty else {
            completion(nil)
            return
        }

        proxy?.stop()
        let lp = LocalProxy(upstreamPort: xrayPort, defaultHost: host)
        proxy = lp
        webHost = host
        lp.start { [weak self] ok in
            guard let self = self else { return }
            if ok, let port = lp.port {
                self.webPort = port
                completion(URL(string: "http://127.0.0.1:\(port)/"))
            } else {
                completion(nil)
            }
        }
    }

    func closeWeb() {
        proxy?.stop()
        proxy = nil
        webPort = 0
        webHost = ""
    }

    /// 把 127.0.0.1 反代地址还原成真实站点地址
    func realURL(from raw: String) -> String {
        guard isRunning, let comp = URLComponents(string: raw) else { return raw }
        let h = comp.host ?? ""
        guard h == "127.0.0.1" || h == "localhost" else { return raw }

        var host = webHost
        var path = comp.path
        if path.hasPrefix("/__x/") {
            let after = String(path.dropFirst(5))
            if let slash = after.firstIndex(of: "/") {
                host = String(after[..<slash])
                path = String(after[slash...])
            }
        }
        guard !host.isEmpty else { return raw }
        let q = comp.query.map { "?\($0)" } ?? ""
        return "https://\(host)\(path.isEmpty ? "/" : path)\(q)"
    }

    // MARK: 配置

    static func makeConfig(link: VmessLink, inport: Int) -> [String: Any] {
        let user: [String: Any] = [
            "id": link.uuid,
            "alterId": link.aid,
            "security": link.cipher.isEmpty ? "auto" : link.cipher,
            "level": 0
        ]
        let vnext: [String: Any] = [
            "address": link.host,
            "port": link.port,
            "users": [user]
        ]

        var ws: [String: Any] = ["path": link.path.isEmpty ? "/" : link.path]
        if !link.hostHeader.isEmpty {
            ws["headers"] = ["Host": link.hostHeader]
        }

        var stream: [String: Any] = [
            "network": link.net.isEmpty ? "ws" : link.net,
            "security": link.tls ? "tls" : "none"
        ]
        if link.net == "ws" || link.net.isEmpty {
            stream["wsSettings"] = ws
        }
        if link.tls {
            var tlsSettings: [String: Any] = ["allowInsecure": true]
            let name = link.sni.isEmpty ? link.hostHeader : link.sni
            if !name.isEmpty { tlsSettings["serverName"] = name }
            stream["tlsSettings"] = tlsSettings
        }

        let outbound: [String: Any] = [
            "tag": "proxy",
            "protocol": "vmess",
            "settings": ["vnext": [vnext]],
            "streamSettings": stream
        ]

        let inbound: [String: Any] = [
            "tag": "http-in",
            "listen": "127.0.0.1",
            "port": inport,
            "protocol": "http",
            "settings": ["timeout": 0, "allowTransparent": false],
            "sniffing": ["enabled": true, "destOverride": ["http", "tls"]]
        ]

        let root: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [inbound],
            "outbounds": [
                outbound,
                ["tag": "direct", "protocol": "freedom"],
                ["tag": "block", "protocol": "blackhole"]
            ],
            "routing": ["domainStrategy": "AsIs"]
        ]
        return root
    }
}
