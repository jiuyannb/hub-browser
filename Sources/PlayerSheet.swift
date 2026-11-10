import SwiftUI
import UIKit
import AVKit

struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        vc.updatesNowPlayingInfoCenter = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

struct PlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var rate: Float = 1.0
    @State private var queued = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player = player {
                    PlayerController(player: player)
                        .ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach([1.0, 1.25, 1.5, 2.0, 0.75, 0.5], id: \.self) { r in
                            Button(String(format: "%.2gx", r)) {
                                rate = Float(r)
                                player?.rate = Float(r)
                            }
                        }
                        Divider()
                        Button {
                            guard !queued else { return }
                            DownloadManager.shared.start(url)
                            queued = true
                        } label: {
                            Label(queued ? "已加入下载队列" : "下载到本地", systemImage: "arrow.down.circle")
                        }
                        Button {
                            UIPasteboard.general.string = url.absoluteString
                        } label: {
                            Label("复制视频直链", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear(perform: setup)
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }

    private func setup() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let p = AVPlayer(url: url)
        p.rate = rate
        p.allowsExternalPlayback = true
        p.play()
        player = p

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: p.currentItem,
                                               queue: .main) { _ in
            p.seek(to: .zero)
        }
    }
}
