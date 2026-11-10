import SwiftUI
import WebKit

/// 实验性：用 WebTorrent 在 WKWebView 里直接连 magnet 直播。
/// 只能连到支持 WebRTC 的 peer，普通种子大概率拿不到数据 —— 拿不到就用「复制到外部下载器」。
struct TorrentPlayer: View {
    let magnet: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TorrentWebView(magnet: magnet)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("磁力在线播放")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            UIPasteboard.general.string = magnet
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
        }
    }
}

struct TorrentWebView: UIViewRepresentable {
    let magnet: String

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.loadHTMLString(Self.html(magnet), baseURL: URL(string: "https://cdn.jsdelivr.net"))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func html(_ magnet: String) -> String {
        let encoded: String
        if let data = try? JSONEncoder().encode(magnet),
           let s = String(data: data, encoding: .utf8) {
            encoded = s
        } else {
            encoded = "\"\""
        }

        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
          body{background:#000;color:#eee;font:14px -apple-system,system-ui;margin:0;padding:14px;-webkit-text-size-adjust:100%}
          h3{font-size:15px;font-weight:600;margin:0 0 10px}
          video{width:100%;background:#0a0a0a;border-radius:10px;aspect-ratio:16/9}
          #log{font-size:12px;color:#8e8e93;white-space:pre-wrap;margin-top:10px;line-height:1.5}
          .btn{display:inline-block;background:#e91e63;color:#fff;padding:9px 16px;border-radius:9px;
               font-size:13px;margin-top:12px;border:0}
        </style>
        </head>
        <body>
        <h3>磁力在线播放（实验）</h3>
        <video id="v" controls playsinline preload="metadata"></video>
        <div id="log">正在初始化…</div>
        <script src="https://cdn.jsdelivr.net/npm/webtorrent@1.9.7/webtorrent.min.js"></script>
        <script>
        var MAGNET = \(encoded);
        var log = document.getElementById('log');
        var v = document.getElementById('v');
        try {
          if (typeof WebTorrent === 'undefined') { log.textContent = '内核加载失败，检查网络后重试'; }
          else {
            var client = new WebTorrent();
            client.on('error', function(e){ log.textContent = '错误：' + (e && e.message ? e.message : e); });
            log.textContent = '正在连接 tracker…';
            client.add(MAGNET, function (t) {
              log.textContent = '已连接，peers: ' + t.numPeers + '，等待数据…';
              var files = t.files.filter(function(f){ return /\\.(mp4|webm|m4v)$/i.test(f.name); });
              files.sort(function(a,b){ return b.length - a.length; });
              if (!files.length) {
                log.textContent = '种子内没有可直接播放的 mp4/webm。点右上角复制磁力链接，交给外部下载器。';
                return;
              }
              var f = files[0];
              log.textContent = '文件：' + f.name + '（' + Math.round(f.length/1048576) + ' MB）\\npeers: ' + t.numPeers;
              f.getBlobURL(function (err, url) {
                if (err) { log.textContent = '取流失败：' + err.message; return; }
                v.src = url;
                v.play().catch(function(){});
                log.textContent = '开始边下边播：' + f.name;
              });
              t.on('download', function (bytes) {
                log.textContent = '已下载 ' + (bytes/1048576).toFixed(1) + ' MB   peers: ' + t.numPeers
                  + '   速度 ' + (t.downloadSpeed/1024).toFixed(0) + ' KB/s';
              });
              t.on('wire', function () {
                log.textContent = 'peers: ' + t.numPeers + '   速度 ' + (t.downloadSpeed/1024).toFixed(0) + ' KB/s';
              });
            });
          }
        } catch (e) {
          log.textContent = '初始化失败：' + e.message;
        }
        </script>
        </body>
        </html>
        """
    }
}
