import SwiftUI
import UIKit

struct MagRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var date = Date()
}

struct MagnetView: View {
    @ObservedObject var store: AppStore

    @State private var keyword = ""
    @State private var engine: MagnetEngine = MagnetEngine.all[0]
    @State private var openSite: Site?
    @State private var openMagnet: String?
    @State private var records: [MagRecord] = Prefs.load([MagRecord].self, "magRecords") ?? []
    @State private var pasteBuffer = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("搜索磁力资源", text: $keyword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(runSearch)
                        Button {
                            runSearch()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Picker("搜索引擎", selection: $engine) {
                        ForEach(MagnetEngine.all) { e in
                            Text(e.name).tag(e)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("磁力搜索")
                }

                Section {
                    HStack {
                        TextField("粘贴 magnet:?xt=urn:btih:...", text: $pasteBuffer)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))
                        Button("打开") {
                            let t = pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard t.hasPrefix("magnet:") else { return }
                            openMagnet = t
                            remember(t)
                            pasteBuffer = ""
                        }
                        .disabled(!pasteBuffer.hasPrefix("magnet:"))
                    }

                    Button {
                        if let s = UIPasteboard.general.string, s.hasPrefix("magnet:") {
                            openMagnet = s
                            remember(s)
                        }
                    } label: {
                        Label("读取剪贴板里的磁力链接", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("直接打开磁力")
                } footer: {
                    Text("磁力本身不含内容，需要 BT 客户端才有 peer。本体内置的是 WebTorrent，只对支持 WebRTC 的种子有效；拿不到数据就复制链接丢给外部下载器。")
                        .font(.caption2)
                }

                if !records.isEmpty {
                    Section("最近磁力") {
                        ForEach(records) { r in
                            Button {
                                openMagnet = r.text
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(shortName(r.text))
                                        .font(.footnote)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(r.date.formatted(date: .numeric, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    records.removeAll { $0.id == r.id }
                                    Prefs.save(records, "magRecords")
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("引擎列表") {
                    ForEach(MagnetEngine.all) { e in
                        Button {
                            var s = Site(name: e.name, url: e.home, category: "磁力", searchTemplate: e.search, icon: "link")
                            s.id = UUID().uuidString
                            openSite = s
                        } label: {
                            HStack {
                                Text(e.name).foregroundStyle(.primary)
                                Spacer()
                                Text(hostOf(e.home)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("磁力")
            .sheet(item: $openSite) { site in
                NavigationStack { BrowserScreen(site: site, store: store) }
            }
            .sheet(item: Binding(
                get: { openMagnet.map { MagBox(text: $0) } },
                set: { if $0 == nil { openMagnet = nil } }
            )) { box in
                MagnetActionSheet(magnet: box.text)
            }
        }
    }

    private func runSearch() {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        var s = Site(name: engine.name,
                     url: engine.search.replacingOccurrences(of: "{q}", with: enc),
                     category: "磁力",
                     searchTemplate: engine.search,
                     icon: "link")
        s.id = UUID().uuidString
        openSite = s
    }

    private func remember(_ t: String) {
        guard !records.contains(where: { $0.text == t }) else { return }
        records.insert(MagRecord(text: t), at: 0)
        if records.count > 50 { records.removeLast(records.count - 50) }
        Prefs.save(records, "magRecords")
    }

    private func shortName(_ t: String) -> String {
        if let r = t.range(of: "&dn=") {
            let rest = t[r.upperBound...]
            let name = rest.split(separator: "&").first.map(String.init) ?? String(rest)
            return name.removingPercentEncoding ?? name
        }
        return String(t.prefix(64))
    }

    private func hostOf(_ s: String) -> String {
        URL(string: s)?.host ?? s
    }
}

struct MagBox: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - 磁力操作面板

struct MagnetActionSheet: View {
    let magnet: String
    @Environment(\.dismiss) private var dismiss
    @State private var showTorrent = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(magnet)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }

                Section {
                    Button {
                        UIPasteboard.general.string = magnet
                        toast = "已复制磁力链接"
                    } label: {
                        Label("复制磁力链接", systemImage: "doc.on.doc")
                    }

                    Button {
                        openExternal()
                    } label: {
                        Label("用外部下载器打开", systemImage: "arrow.up.forward.app")
                    }

                    Button {
                        showTorrent = true
                    } label: {
                        Label("内置在线播放（实验）", systemImage: "play.rectangle")
                    }
                } footer: {
                    Text("iOS 不允许后台跑 BT。要真正下载，装一个 BT 客户端（iTorrent / BitTorrent / qBittorrent），再点「用外部下载器打开」。")
                        .font(.caption2)
                }
            }
            .navigationTitle("磁力链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toast = nil }
                        }
                }
            }
            .fullScreenCover(isPresented: $showTorrent) {
                TorrentPlayer(magnet: magnet)
            }
        }
    }

    private func openExternal() {
        guard let url = URL(string: magnet) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                UIPasteboard.general.string = magnet
                toast = "没有 BT 客户端，已复制到剪贴板"
            }
        }
    }
}
