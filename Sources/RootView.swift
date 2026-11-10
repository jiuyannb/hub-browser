import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var searchSite: Site?

    private var categories: [String] {
        var seen: [String] = []
        for s in store.sites where !seen.contains(s.category) {
            seen.append(s.category)
        }
        return seen
    }

    var body: some View {
        TabView {
            sitesTab
                .tabItem { Label("站点", systemImage: "square.grid.2x2.fill") }

            MagnetView(store: store)
                .tabItem { Label("磁力", systemImage: "link") }

            AirportView()
                .tabItem { Label("机场", systemImage: "airplane") }

            bookmarksTab
                .tabItem { Label("收藏", systemImage: "bookmark.fill") }

            settingsTab
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .sheet(item: $searchSite) { site in
            NavigationStack {
                BrowserScreen(site: site, store: store)
            }
        }
    }

    // MARK: 站点

    private var sitesTab: some View {
        NavigationStack {
            List {
                ForEach(categories, id: \.self) { cat in
                    Section(cat) {
                        ForEach(store.sites.filter { $0.category == cat }) { site in
                            NavigationLink {
                                BrowserScreen(site: site, store: store)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: site.icon)
                                        .frame(width: 22)
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(site.name)
                                        Text(host(site.url))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("黄片大王")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索内容")
            .onSubmit(of: .search, runSearch)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        runSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(query.isEmpty)
                }
            }
        }
    }

    // MARK: 收藏

    private var bookmarksTab: some View {
        NavigationStack {
            List {
                ForEach(store.bookmarks) { item in
                    Button {
                        var s = Site(name: item.site.isEmpty ? item.title : item.site,
                                     url: item.url,
                                     category: "",
                                     searchTemplate: nil)
                        s.id = UUID().uuidString
                        searchSite = s
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).lineLimit(1).foregroundStyle(.primary)
                            Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .onDelete { index in
                    index.map { store.bookmarks[$0] }.forEach(store.removeBookmark)
                }
            }
            .navigationTitle("收藏")
            .overlay {
                if store.bookmarks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bookmark.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("还没有收藏").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 设置

    private var settingsTab: some View {
        NavigationStack {
            List {
                ProxySection()

                Section("浏览") {
                    Toggle("无痕模式", isOn: Binding(
                        get: { store.incognito },
                        set: { store.incognito = $0; Prefs.set($0, "incognito") }))

                    Toggle("拦截广告与弹窗", isOn: Binding(
                        get: { store.blockAds },
                        set: { store.blockAds = $0; Prefs.set($0, "blockAds") }))

                    Toggle("请求桌面版网页", isOn: Binding(
                        get: { store.desktopUA },
                        set: { store.desktopUA = $0; Prefs.set($0, "desktopUA") }))
                }

                Section("下载") {
                    NavigationLink {
                        DownloadListView()
                    } label: {
                        HStack {
                            Text("下载管理")
                            Spacer()
                            Text("\(DownloadManager.shared.items.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("记录") {
                    NavigationLink("浏览历史（\(store.history.count)）") {
                        List(store.history) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).lineLimit(1)
                                Text(item.site + " · " + item.url)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .navigationTitle("浏览历史")
                    }

                    Button("清空历史") { store.clearHistory() }
                    Button("清除网页缓存与 Cookie", role: .destructive) { store.clearWebData() }
                }

                Section("说明") {
                    Text("站点清单在 Sources/Models.swift 的 Site.defaults，改完在 GitHub 上 commit 就会自动重新编译。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("切换无痕模式或桌面 UA 后需重新进入站点生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }

    private func host(_ s: String) -> String {
        URL(string: s)?.host ?? s
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let candidates = store.sites.filter { ($0.searchTemplate ?? "").contains("{q}") }
        guard let template = candidates.first(where: { $0.category == "视频" }) ?? candidates.first,
              let encoded = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: template.searchTemplate!.replacingOccurrences(of: "{q}", with: encoded))
        else { return }

        var s = template
        s.id = UUID().uuidString
        s.url = url.absoluteString
        searchSite = s
    }
}

// MARK: - 下载列表

struct DownloadListView: View {
    @ObservedObject var manager = DownloadManager.shared

    var body: some View {
        List {
            ForEach(manager.items) { item in
                DownloadRow(item: item)
                    .swipeActions {
                        Button(role: .destructive) {
                            manager.remove(item)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle("下载管理")
        .overlay {
            if manager.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有下载任务").foregroundStyle(.secondary)
                    Text("在播放页右上角菜单里点「下载到本地」")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - 内置代理

struct ProxySection: View {
    @ObservedObject var engine = ProxyEngine.shared
    @State private var nodes: [ProxyNode] = []
    @State private var picking = false
    @State private var message = ""

    private var statusText: String {
        switch engine.state {
        case .idle: return "未连接（走系统网络）"
        case .starting: return "启动中…"
        case .running: return "已连接 " + engine.activeName
        case .failed(let m): return "失败：" + m
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .running: return .green
        case .failed: return .red
        case .starting: return .orange
        case .idle: return .secondary
        }
    }

    var body: some View {
        Section {
            HStack {
                Text("状态")
                Spacer()
                Text(statusText)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
                    .font(.footnote)
            }

            if engine.isRunning {
                Button("断开内置代理", role: .destructive) {
                    engine.stop()
                    message = ""
                }
            } else {
                Button("选择节点并连接") {
                    picking = true
                }
                .disabled(nodes.isEmpty)
            }

            if let n = Prefs.loadSingle(ProxyNode.self, "proxyNode"), !engine.isRunning {
                HStack {
                    Text("上次")
                    Spacer()
                    Text(n.name).foregroundStyle(.secondary).font(.footnote)
                }
                Button("一键重连「\(n.name)」") {
                    connect(n)
                }
            }

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("内置代理（不用开 VPN 就能上网）")
        } footer: {
            Text(nodes.isEmpty
                 ? "先去「机场」Tab 添加订阅，这里才有节点可选。只支持 vmess 节点（ws / tcp 均可）。"
                 : "连接后 App 内网页走你选的节点出网，不影响系统网络。Xray 内核 \(engine.xrayInfo)")
                .font(.caption2)
        }
        .onAppear {
            nodes = Prefs.load([ProxyNode].self, "subNodes") ?? []
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                List {
                    ForEach(nodes.filter { $0.raw.lowercased().hasPrefix("vmess://") }) { node in
                        Button {
                            picking = false
                            connect(node)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(node.name).foregroundStyle(.primary)
                                Text(node.host + ":" + String(node.port))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("选择节点")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("取消") { picking = false }
                    }
                }
                .overlay {
                    let list = nodes.filter { $0.raw.lowercased().hasPrefix("vmess://") }
                    if list.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "airplane.circle").font(.largeTitle).foregroundStyle(.secondary)
                            Text("没有可用的 vmess 节点").foregroundStyle(.secondary)
                            Text("机场 Tab 里重新拉一次订阅").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func connect(_ node: ProxyNode) {
        message = "连接中…"
        engine.start(node: node) { ok, msg in
            message = msg
            if !ok {
                nodes = Prefs.load([ProxyNode].self, "subNodes") ?? []
            }
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.footnote)
                .lineLimit(1)

            if item.state == .running {
                ProgressView(value: item.progress)
                    .tint(.pink)
            }

            HStack {
                Text(item.state.rawValue)
                    .font(.caption2)
                    .foregroundStyle(item.state == .failed ? .red : .secondary)
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if item.state == .done {
                    Button(saved ? "已存相册" : "存相册") {
                        DownloadManager.shared.saveToAlbum(item) { ok in
                            if ok { saved = true }
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}
