import Foundation

// MARK: - 内置 BT 下载引擎（magnet → 最大文件）

final class TorrentEngine {

    enum Phase {
        case idle
        case finding
        case metadata
        case downloading
        case done
        case failed
    }

    private(set) var phase: Phase = .idle

    private let magnet: MagnetInfo
    private let peerID: Data
    private let listenPort: UInt16 = UInt16.random(in: 40000...60000)

    private var links: [PeerLink] = []

    private var metaPieces: [Int: Data] = [:]
    private var metaSize = 0
    private var metaDone = false

    private var pieceLength = 0
    private var piecesCount = 0
    private var totalLength = 0
    private var targetName = "video"
    private var targetOffset = 0
    private var targetLength = 0

    private var fileHandle: FileHandle?
    private var destPath = ""

    private var pieceQueue: [Int] = []
    private var currentPiece = -1
    private var currentData: [UInt8] = []
    private var currentBlocksTotal = 0
    private var currentBlocksDone = 0
    private var lastDispatch = Date()

    private var downloaded = 0
    private var lastSample = 0
    private var timer: Timer?
    private var fired = false

    var onStatus: ((String) -> Void)?
    var onProgress: ((Double, String) -> Void)?
    var onDone: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private let fallbackTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
        "https://tracker.tamersunion.org:443/announce"
    ]

    init(magnet: MagnetInfo) {
        self.magnet = magnet
        var p = Data()
        p.append(contentsOf: Array("-DS0001-".utf8))
        for _ in 0..<12 {
            p.append(UInt8.random(in: 48...122))
        }
        self.peerID = Data(p.prefix(20))
    }

    // MARK: 启动

    func start() {
        guard phase == .idle else { return }
        phase = .finding
        onStatus?("正在查询 tracker…")

        var set = Set<PeerAddr>()
        let lock = NSLock()
        let group = DispatchGroup()
        let trackers = magnet.trackers + fallbackTrackers

        for t in trackers {
            group.enter()
            Tracker.announce(url: t,
                             infoHash: magnet.infoHash,
                             peerID: peerID,
                             port: listenPort,
                             left: 0) { peers in
                lock.lock()
                for p in peers { set.insert(p) }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.connect(Array(set))
        }
        startTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let delta = self.downloaded - self.lastSample
            self.lastSample = self.downloaded
            let speed = max(0, delta)
            if self.phase == .downloading, self.targetLength > 0 {
                let ratio = min(1.0, Double(self.downloaded) / Double(self.targetLength))
                let text = "\(fmt(speed))/s · \(fmt(self.downloaded))/\(fmt(self.targetLength))"
                self.onProgress?(ratio, text)
            }
            if Date().timeIntervalSince(self.lastDispatch) > 5, self.phase == .downloading {
                self.redispatch()
            }
        }
    }

    private func fmt(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / 1048576) }
        return String(format: "%.2f GB", b / 1073741824)
    }

    // MARK: 连接

    private func connect(_ peers: [PeerAddr]) {
        guard !peers.isEmpty else {
            fail("所有 tracker 都没返回节点，这个种子可能没人做种了")
            return
        }
        onStatus?("拿到 \(peers.count) 个节点，正在连接…")
        for addr in peers.prefix(30) {
            let link = PeerLink(addr: addr, infoHash: magnet.infoHash, peerID: peerID)
            link.onExtended = { [weak self, weak link] extID, data in
                guard let self = self, let l = link else { return }
                self.handleExtended(l, extID, data)
            }
            link.onMessage = { [weak self, weak link] id, body in
                guard let self = self, let l = link else { return }
                self.handleMessage(l, id, body)
            }
            links.append(link)
            link.start()
        }
    }

    // MARK: 扩展协议 / metadata

    private func handleExtended(_ link: PeerLink, _ extID: Int, _ data: Data) {
        if extID == 0 {
            guard let (v, _) = BParser.parsePrefix(data), let d = v.dictValue else { return }
            if let m = d["m"]?.dictValue, let u = m["ut_metadata"]?.intValue {
                link.peerMetaID = u
                requestMeta(link, 0)
            }
            return
        }
        guard let (v, used) = BParser.parsePrefix(data), let d = v.dictValue else { return }
        guard (d["msg_type"]?.intValue ?? 0) == 1 else { return }
        let idx = d["piece"]?.intValue ?? 0
        metaSize = d["total_size"]?.intValue ?? 0
        let raw = data.dropFirst(used)
        if !raw.isEmpty {
            metaPieces[idx] = Data(raw)
        }
        onStatus?("接收种子信息 \(metaPieces.count) 片")
        let need = (metaSize + 16383) / 16384
        if metaPieces.count < need {
            let next = idx + 1
            if next < need { requestMeta(link, next) }
        } else if !metaDone, need > 0 {
            metaDone = true
            assemble()
        }
    }

    private func requestMeta(_ link: PeerLink, _ idx: Int) {
        guard let mid = link.peerMetaID else { return }
        let body = Array("d8:msg_typei0e5:piecei\(idx)ee".utf8)
        link.sendExtension(UInt8(clamping: mid), body)
    }

    private func assemble() {
        var all = Data()
        var i = 0
        while let p = metaPieces[i] {
            all.append(p)
            i += 1
        }
        guard let v = try? BParser.parse(all), let dict = v.dictValue else {
            fail("种子信息解析失败")
            return
        }
        parseInfo(dict)
    }

    // MARK: 文件结构

    private func parseInfo(_ d: [String: BValue]) {
        pieceLength = d["piece length"]?.intValue ?? 0
        let pieces = d["pieces"]?.dataValue ?? Data()
        piecesCount = pieces.count / 20
        guard pieceLength > 0, piecesCount > 0 else {
            fail("种子结构异常")
            return
        }

        var files: [(name: String, len: Int, off: Int)] = []
        if let single = d["length"]?.intValue, let name = d["name"]?.stringValue {
            files.append((name, single, 0))
        } else if let list = d["files"]?.listValue {
            var off = 0
            for f in list {
                let len = f["length"]?.intValue ?? 0
                let path = (f["path"]?.listValue ?? []).compactMap { $0.stringValue }.joined(separator: "_")
                files.append((path.isEmpty ? "file" : path, len, off))
                off += len
            }
        }
        guard !files.isEmpty else {
            fail("种子内没有文件")
            return
        }
        totalLength = files.reduce(0) { $0 + $1.len }
        let best = files.max { $0.len < $1.len }!
        targetName = best.name
        targetOffset = best.off
        targetLength = best.len
        guard targetLength > 0 else {
            fail("文件长度为 0")
            return
        }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var safe = targetName
        if let last = safe.components(separatedBy: "/").last { safe = last }
        if safe.isEmpty { safe = "video" }
        let url = dir.appendingPathComponent(safe)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        destPath = url.path

        let start = targetOffset / pieceLength
        let end = (targetOffset + targetLength - 1) / pieceLength
        if end >= start {
            pieceQueue = Array(start...end)
        }
        phase = .downloading
        onStatus?("开始下载 \(safe)")
        nextPiece()
    }

    // MARK: 分片调度

    private func nextPiece() {
        guard let first = pieceQueue.first else {
            finish()
            return
        }
        pieceQueue.removeFirst()
        currentPiece = first
        let absStart = currentPiece * pieceLength
        var len = pieceLength
        if absStart + pieceLength > totalLength { len = totalLength - absStart }
        guard len > 0 else {
            nextPiece()
            return
        }
        currentData = [UInt8](repeating: 0, count: len)
        currentBlocksTotal = (len + 16383) / 16384
        currentBlocksDone = 0
        lastDispatch = Date()
        dispatchBlocks()
    }

    private func dispatchBlocks() {
        let pool = links.filter { !$0.choked && $0.peerMetaID != nil }
        guard !pool.isEmpty, currentPiece >= 0, currentData.count > 0 else { return }
        var i = 0
        for block in 0..<currentBlocksTotal {
            let link = pool[i % pool.count]
            i += 1
            let begin = block * 16384
            let len = min(16384, currentData.count - begin)
            if len <= 0 { continue }
            var req: [UInt8] = []
            req.append(contentsOf: UDPAnnounce.be32(UInt32(currentPiece)))
            req.append(contentsOf: UDPAnnounce.be32(UInt32(begin)))
            req.append(contentsOf: UDPAnnounce.be32(UInt32(len)))
            link.sendMessage(6, req)
        }
    }

    private func redispatch() {
        lastDispatch = Date()
        dispatchBlocks()
    }

    private func handleMessage(_ link: PeerLink, _ id: UInt8, _ body: [UInt8]) {
        switch id {
        case 0:
            link.choked = true
        case 1:
            link.choked = false
            dispatchBlocks()
        case 7:
            guard body.count >= 8 else { return }
            let index = Int(readBE32(body, 0))
            let begin = Int(readBE32(body, 4))
            guard index == currentPiece, begin >= 0, begin < currentData.count else { return }
            let payload = Array(body.dropFirst(8))
            let end = min(begin + payload.count, currentData.count)
            guard end > begin else { return }
            currentData.replaceSubrange(begin..<end, with: payload[0..<(end - begin)])
            currentBlocksDone += 1
            if currentBlocksDone >= currentBlocksTotal {
                writeCurrentPiece()
                nextPiece()
            }
        default:
            break
        }
    }

    private func readBE32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private func writeCurrentPiece() {
        guard let fh = fileHandle, currentPiece >= 0 else { return }
        let absStart = currentPiece * pieceLength
        let pieceEnd = absStart + currentData.count
        let fileStart = targetOffset
        let fileEnd = targetOffset + targetLength
        let s = max(absStart, fileStart)
        let e = min(pieceEnd, fileEnd)
        guard s < e else { return }
        let from = s - absStart
        let to = e - absStart
        let chunk = Data(currentData[from..<to])
        do {
            try fh.seek(toOffset: UInt64(s - fileStart))
            try fh.write(contentsOf: chunk)
        } catch {
            fail("写入文件失败")
            return
        }
        downloaded += chunk.count
    }

    // MARK: 收尾

    private func finish() {
        if fired { return }
        fired = true
        phase = .done
        timer?.invalidate()
        timer = nil
        try? fileHandle?.close()
        for l in links { l.close() }
        onProgress?(1.0, fmt(targetLength) + " 完成")
        onStatus?("下载完成")
        let url = URL(fileURLWithPath: destPath)
        onDone?(url)
    }

    private func fail(_ reason: String) {
        if fired { return }
        fired = true
        phase = .failed
        timer?.invalidate()
        timer = nil
        for l in links { l.close() }
        onStatus?(reason)
        onError?(reason)
    }

    func cancel() {
        fired = true
        timer?.invalidate()
        timer = nil
        for l in links { l.close() }
        links.removeAll()
        try? fileHandle?.close()
    }
}
