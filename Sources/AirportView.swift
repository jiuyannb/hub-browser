import SwiftUI

struct AirportView: View {
    @State private var subs: [SubEntry] = []
    @State private var nodes: [ProxyNode] = []
    @State private var subURL = ""
    @State private var subName = ""
    @State private var loading = false
    @State private var testing = false
    @State private var msg = ""
    @State private var checker = "未检测"
    @State private var checking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: checker.hasPrefix("通") ? "wifi" : "wifi.slash")
                            .foregroundStyle(checker.hasPrefix("通") ? .green : .orange)
                        Text(checker)
                        Spacer()
                        Button(checking ? "检测中…" : "检测网络") { checkNet() }
                            .disabled(checking)
                    }
                } header: {
                    Text("网络")
                } footer: {
                    Text("这里只做连通性自检：能连上 Google 说明系统级代理已在工作，站点的视频才可能播得出来。")
                        .font(.caption2)
                }

                Section {
                    TextField("https://订阅地址", text: $subURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("备注名（可空）", text: $subName)
                    Button(loading ? "拉取中…" : "添加并拉取节点") { add() }
                        .disabled(subURL.isEmpty || loading)
                    if !msg.isEmpty {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("添加订阅")
                }

                if !subs.isEmpty {
                    Section("我的订阅") {
                        ForEach(subs) { s in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(s.name).font(.headline)
                                Text("\(s.count) 个节点 · \(s.url)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 16) {
                                    Button("更新") { refresh(s) }
                                    Button("导入小火箭") { toRocket(s) }
                                    Button("删除") { remove(s) }
                                        .foregroundStyle(.red)
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if !nodes.isEmpty {
                    Section {
                        HStack {
                            Text("\(nodes.count) 个节点").font(.footnote)
                            Spacer()
                            Button(testing ? "测速中…" : "测全部延迟") { testAll() }
                                .font(.caption)
                                .disabled(testing)
                        }
                        ForEach(nodes) { n in
                            HStack(spacing: 10) {
                                Text(n.type.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.name).font(.subheadline).lineLimit(1)
                                    Text("\(n.host):\(n.port)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(n.latency.map { "\($0) ms" } ?? "—")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(color(n.latency))
                            }
                        }
                    } header: {
                        Text("节点")
                    } footer: {
                        Text("延迟是 TCP 握手时间，只说明线路通不通，不代表能解锁流媒体。")
                            .font(.caption2)
                    }
                }

                Section {
                    Text("怎么让它真正起效：这里拉取订阅 → 导入小火箭 / Clash / sing-box → 在那边开全局 → 回到「站点」刷页面。本 App 是普通 App，签名证书里不带 VPN 隧道权限，隧道由系统代理 App 来跑。")
                        .font(.caption)
                }
            }
            .navigationTitle("机场")
            .onAppear { loadAll() }
        }
    }

    // MARK: 操作

    private func color(_ ms: Int?) -> Color {
        guard let ms = ms else { return .secondary }
        if ms < 200 { return .green }
        if ms < 600 { return .orange }
        return .red
    }

    private func loadAll() {
        subs = read([SubEntry].self, "subs") ?? []
        nodes = read([ProxyNode].self, "subNodes") ?? []
    }

    private func read<T: Codable>(_ t: T.Type, _ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }

    private func write<T: Codable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    private func checkNet() {
        checking = true
        checker = "检测中…"
        Latency.test(host: "www.google.com", port: 443, timeout: 4) { ms in
            checking = false
            if let ms = ms {
                checker = "通 · google.com \(ms) ms"
            } else {
                checker = "不通 · 系统代理没开或线路挂了"
            }
        }
    }

    private func add() {
        fetch(subURL.trimmingCharacters(in: .whitespacesAndNewlines), name: subName, replace: nil)
    }

    private func refresh(_ s: SubEntry) {
        fetch(s.url, name: s.name, replace: s)
    }

    private func fetch(_ urlText: String, name: String, replace: SubEntry?) {
        guard let url = URL(string: urlText) else {
            msg = "链接格式不对"
            return
        }
        loading = true
        msg = ""
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("Clash/1.20.0", forHTTPHeaderField: "User-Agent")
        req.setValue("clash", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                loading = false
                if let err = err {
                    msg = "拉取失败：" + err.localizedDescription
                    return
                }
                guard let data = data, let text = String(data: data, encoding: .utf8) else {
                    msg = "拉取失败：内容为空"
                    return
                }
                let parsed = SubParser.parse(text)
                guard !parsed.isEmpty else {
                    msg = "解析出 0 个节点，可能订阅已改版或需要专属 UA"
                    return
                }
                nodes = parsed
                if let old = replace, let idx = subs.firstIndex(where: { $0.id == old.id }) {
                    subs[idx].count = parsed.count
                    subs[idx].updated = Date()
                } else {
                    let n = name.isEmpty ? (URL(string: urlText)?.host ?? "订阅") : name
                    var e = SubEntry(name: n, url: urlText)
                    e.count = parsed.count
                    subs.insert(e, at: 0)
                }
                write(subs, "subs")
                write(nodes, "subNodes")
                subURL = ""
                subName = ""
                msg = "成功拉取 \(parsed.count) 个节点"
            }
        }.resume()
    }

    private func remove(_ s: SubEntry) {
        subs.removeAll { $0.id == s.id }
        write(subs, "subs")
    }

    private func toRocket(_ s: SubEntry) {
        let b = Data(s.url.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let remark = s.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "sub"
        let list = [
            "shadowrocket://add/sub://\(b)?remark=\(remark)",
            "quantumult-x:///add-resource?remote-resource=\(b)",
            "clash://install-config?url=\(s.url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")",
            "sing-box://import-remote-profile?url=\(s.url)"
        ]
        for str in list {
            if let u = URL(string: str), UIApplication.shared.canOpenURL(u) {
                UIApplication.shared.open(u)
                msg = "已交给外部客户端"
                return
            }
        }
        UIPasteboard.general.string = s.url
        msg = "没检测到小火箭/圈X/Clash，订阅链接已复制到剪贴板"
    }

    private func testAll() {
        testing = true
        let count = nodes.count
        let group = DispatchGroup()
        for i in 0..<count {
            nodes[i].latency = nil
            group.enter()
            let h = nodes[i].host
            let p = nodes[i].port
            Latency.test(host: h, port: p) { ms in
                if i < self.nodes.count {
                    self.nodes[i].latency = ms
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            testing = false
            write(nodes, "subNodes")
        }
    }
}
