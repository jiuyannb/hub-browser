import SwiftUI
import WebKit

struct WebContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserScreen: View {
    let site: Site
    @ObservedObject var store: AppStore
    @StateObject private var model: BrowserModel
    @State private var appeared = false
    @State private var magnetText: String?

    init(site: Site, store: AppStore) {
        self.site = site
        self.store = store
        _model = StateObject(wrappedValue: BrowserModel(incognito: store.incognito,
                                                        blockAds: store.blockAds,
                                                        desktopUA: store.desktopUA))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.pink)
            }

            WebContainer(webView: model.webView)

            bottomBar
        }
        .navigationTitle(model.pageTitle.isEmpty ? site.name : model.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !appeared else { return }
            appeared = true
            model.onLoaded = { title, url in
                let real = ProxyEngine.shared.realURL(from: url)
                store.record(Bookmark(title: title, url: real, site: site.name))
            }
            model.onMagnet = { m in
                magnetText = m
            }
            if ProxyEngine.shared.isRunning {
                ProxyEngine.shared.open(site: site) { entry in
                    DispatchQueue.main.async {
                        if let entry = entry {
                            model.load(entry, site: site.name)
                        } else if let url = URL(string: site.url) {
                            model.load(url, site: site.name)
                        }
                    }
                }
            } else if let url = URL(string: site.url) {
                model.load(url, site: site.name)
            }
        }
        .fullScreenCover(item: $model.playing) { item in
            PlayerSheet(url: item.url)
        }
        .sheet(item: Binding(
            get: { magnetText.map { MagBox(text: $0) } },
            set: { if $0 == nil { magnetText = nil } }
        )) { box in
            MagnetActionSheet(magnet: box.text)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 26) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
            }
            .disabled(!model.canBack)

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold))
            }
            .disabled(!model.canForward)

            Button {
                if model.isLoading { model.stop() } else { model.reload() }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 17, weight: .semibold))
            }

            Spacer()

            Button {
                store.addBookmark(Bookmark(title: model.pageTitle.isEmpty ? model.address : model.pageTitle,
                                           url: ProxyEngine.shared.realURL(from: model.address),
                                           site: site.name))
            } label: {
                Image(systemName: "bookmark").font(.system(size: 17, weight: .semibold))
            }

            if let url = URL(string: ProxyEngine.shared.realURL(from: model.address)) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
