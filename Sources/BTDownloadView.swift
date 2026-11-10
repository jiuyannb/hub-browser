import SwiftUI
import AVKit
import Photos

struct BTDownloadView: View {
    let magnetText: String
    @Environment(\.dismiss) private var dismiss

    @State private var engine: TorrentEngine?
    @State private var status = "准备中…"
    @State private var progress = 0.0
    @State private var detail = ""
    @State private var doneURL: URL?
    @State private var err: String?
    @State private var playing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(magnetText)
                        .font(.caption2)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("磁力")
                }

                Section {
                    HStack {
                        Text(status).font(.subheadline)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                    ProgressView(value: progress)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("进度")
                } footer: {
                    Text("直连 peer 下载，不做 DHT。种子没人做种、或只有 UDP 之外的内网节点时会拿不到数据。")
                        .font(.caption2)
                }

                if let u = doneURL {
                    Section("完成") {
                        Button {
                            playing = true
                        } label: {
                            Label("播放", systemImage: "play.circle.fill")
                        }
                        Button {
                            saveToAlbum(u)
                        } label: {
                            Label("存入相册", systemImage: "square.and.arrow.down")
                        }
                        Text(u.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let e = err {
                    Section {
                        Text(e).font(.caption).foregroundStyle(.red)
                        Button("重试") {
                            engine?.cancel()
                            err = nil
                            progress = 0
                            doneURL = nil
                            begin()
                        }
                    }
                }
            }
            .navigationTitle("磁力下载")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        engine?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear { begin() }
            .fullScreenCover(isPresented: $playing) {
                if let u = doneURL {
                    LocalVideo(url: u)
                }
            }
        }
    }

    private func begin() {
        guard let m = MagnetInfo.parse(magnetText) else {
            err = "磁力链接解析失败"
            status = "失败"
            return
        }
        let e = TorrentEngine(magnet: m)
        e.onStatus = { s in status = s }
        e.onProgress = { p, d in
            progress = p
            detail = d
        }
        e.onDone = { u in
            doneURL = u
        }
        e.onError = { s in
            err = s
        }
        engine = e
        e.start()
    }

    private func saveToAlbum(_ url: URL) {
        PHPhotoLibrary.requestAuthorization { _ in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, _ in
                DispatchQueue.main.async {
                    detail = ok ? "已保存到相册" : "保存失败，文件留在 App 的 Downloads 里"
                }
            }
        }
    }
}

struct LocalVideo: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let player = AVPlayer(url: url)
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        player.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
