import SwiftUI
import WebKit

final class BrowserModel: NSObject, ObservableObject {
    @Published var pageTitle = ""
    @Published var address = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canBack = false
    @Published var canForward = false
    @Published var playing: PlayItem?
    @Published var siteName = ""

    let webView: WKWebView
    var onLoaded: ((String, String) -> Void)?
    var onMagnet: ((String) -> Void)?
    var onMediaLink: ((URL) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var didInject = false

    init(incognito: Bool, blockAds: Bool, desktopUA: Bool) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        if incognito {
            config.websiteDataStore = .nonPersistent()
        }

        let controller = WKUserContentController()
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.customUserAgent = desktopUA
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        controller.add(self, name: "play")
        injectBridge()
        startObserving()
        if blockAds { installRules() }
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    func load(_ url: URL, site: String = "") {
        siteName = site
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    // MARK: - KVO

    private func startObserving() {
        observations.append(webView.observe(\.title) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.pageTitle = wv.title ?? "" }
        })
        observations.append(webView.observe(\.url) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.address = wv.url?.absoluteString ?? "" }
        })
        observations.append(webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.progress = wv.estimatedProgress }
        })
        observations.append(webView.observe(\.isLoading) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.isLoading = wv.isLoading }
        })
        observations.append(webView.observe(\.canGoBack) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.canBack = wv.canGoBack }
        })
        observations.append(webView.observe(\.canGoForward) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.canForward = wv.canGoForward }
        })
    }

    // MARK: - 注入

    private func injectBridge() {
        let js = """
        (function(){
          try{
            window.open = function(u){ if(u){ location.href = u; } return null; };
            window.alert = function(){};
            window.confirm = function(){ return true; };
            window.prompt = function(){ return null; };
            document.addEventListener('click', function(e){
              var t = e.target;
              while(t && t.tagName !== 'A'){ t = t.parentElement; }
              if(!t){ return; }
              var h = t.href || '';
              if(/\\.(m3u8|mp4|flv)(\\?|#|$)/i.test(h)){
                e.preventDefault();
                e.stopPropagation();
                try{ window.webkit.messageHandlers.play.postMessage(h); }catch(err){}
              }
            }, true);
            var kill = function(){
              document.querySelectorAll('div,section,aside').forEach(function(el){
                var s = getComputedStyle(el);
                if(s.position === 'fixed' && parseInt(s.zIndex || '0', 10) > 99 && el.offsetHeight > 200 && el.offsetWidth > 200){
                  el.style.display = 'none';
                }
              });
            };
            setTimeout(kill, 1500);
          }catch(e){}
        })();
        """
        let script = WKUserScript(source: js,
                                 injectionTime: .atDocumentEnd,
                                 forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(script)
    }

    private func installRules() {
        let json = """
        [
          {"trigger":{"url-filter":".*","resource-type":["popup"]},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://([^/]+\\\\.)?(doubleclick|googlesyndication|google-analytics|googletagmanager|adservice|adnxs|taboola|outbrain|popads|exoclick|juicyads|trafficjunky|adsterra|propellerads|onclickads|popcash|clksite)\\\\.","resource-type":["script","image","style-sheet","raw","document","media","popup"]},"action":{"type":"block"}},
          {"trigger":{"url-filter":"/(ads?|advert|banner)[0-9_-]*\\\\.(js|html)","resource-type":["script","document"]},"action":{"type":"block"}}
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "hub-adblock-v1",
                                                                encodedContentRuleList: json) { [weak self] list, _ in
            guard let list = list else { return }
            DispatchQueue.main.async {
                self?.webView.configuration.userContentController.add(list)
            }
        }
    }
}

// MARK: - 导航

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = (url.scheme ?? "").lowercased()

        if scheme == "magnet" {
            decisionHandler(.cancel)
            let raw = url.absoluteString
            DispatchQueue.main.async { self.onMagnet?(raw) }
            return
        }

        if ["thunder", "ed2k", "itms-services", "intent", "whatsapp", "tg", "line"].contains(scheme) {
            decisionHandler(.cancel)
            return
        }

        let ext = url.pathExtension.lowercased()
        if (ext == "m3u8" || ext == "mp4" || ext == "flv"),
           navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            DispatchQueue.main.async { self.playing = PlayItem(url: url) }
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        let title = webView.title ?? url
        onLoaded?(title, url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}
}

// MARK: - 窗口 / 弹窗

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

// MARK: - JS 桥

extension BrowserModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "play",
              let raw = message.body as? String,
              let url = URL(string: raw) else { return }
        DispatchQueue.main.async { self.playing = PlayItem(url: url) }
    }
}

// MARK: - 播放项

struct PlayItem: Identifiable {
    let id = UUID()
    let url: URL
}
