import Foundation
import Photos
import UIKit

final class DownloadItem: Identifiable, ObservableObject {
    enum State: String {
        case waiting = "等待中"
        case running = "下载中"
        case done = "已完成"
        case failed = "失败"
    }

    let id = UUID()
    let url: URL
    let name: String
    let started = Date()

    @Published var progress: Double = 0
    @Published var state: State = .waiting
    @Published var detail: String = ""
    @Published var localPath: String?

    init(url: URL) {
        self.url = url
        var n = url.lastPathComponent
        if n.isEmpty { n = "video_\(Int(Date().timeIntervalSince1970)).mp4" }
        self.name = n
    }
}

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var items: [DownloadItem] = []

    private var map: [Int: DownloadItem] = [:]
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    var folder: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func start(_ url: URL) {
        let item = DownloadItem(url: url)
        items.insert(item, at: 0)
        item.state = .running
        let task = session.downloadTask(with: URLRequest(url: url))
        task.taskDescription = item.id.uuidString
        map[task.taskIdentifier] = item
        task.resume()
    }

    func remove(_ item: DownloadItem) {
        items.removeAll { $0.id == item.id }
        if let p = item.localPath {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    func saveToAlbum(_ item: DownloadItem, completion: @escaping (Bool) -> Void) {
        guard let p = item.localPath else { completion(false); return }
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: URL(fileURLWithPath: p))
            } completionHandler: { ok, _ in
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let item = map[downloadTask.taskIdentifier] else { return }
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async {
            item.progress = p
            let mb = Double(totalBytesWritten) / 1_048_576
            let total = totalBytesExpectedToWrite > 0 ? String(format: "%.1f MB", Double(totalBytesExpectedToWrite) / 1_048_576) : "未知"
            item.detail = String(format: "%.1f MB / %@", mb, total)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let item = map[downloadTask.taskIdentifier] else { return }
        let dest = folder.appendingPathComponent(item.name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async {
                item.progress = 1
                item.state = .done
                item.localPath = dest.path
                item.detail = "已保存到沙盒 Downloads"
            }
        } catch {
            DispatchQueue.main.async {
                item.state = .failed
                item.detail = error.localizedDescription
            }
        }
        map.removeValue(forKey: downloadTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error = error, let item = map[task.taskIdentifier] else { return }
        DispatchQueue.main.async {
            item.state = .failed
            item.detail = error.localizedDescription
        }
        map.removeValue(forKey: task.taskIdentifier)
    }
}
