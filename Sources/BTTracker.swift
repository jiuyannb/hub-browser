import Foundation
import Network

// MARK: - Tracker announce

enum Tracker {

    static func announce(url: String,
                         infoHash: Data,
                         peerID: Data,
                         port: UInt16,
                         left: Int,
                         completion: @escaping ([PeerAddr]) -> Void) {
        if url.lowercased().hasPrefix("udp") {
            UDPAnnounce.run(url: url, infoHash: infoHash, peerID: peerID, port: port, left: left, completion: completion)
        } else {
            httpAnnounce(url: url, infoHash: infoHash, peerID: peerID, port: port, left: left, completion: completion)
        }
    }

    // MARK: HTTP

    private static func httpAnnounce(url: String,
                                     infoHash: Data,
                                     peerID: Data,
                                     port: UInt16,
                                     left: Int,
                                     completion: @escaping ([PeerAddr]) -> Void) {
        let hashEnc = infoHash.map { String(format: "%%%02X", $0) }.joined()
        let pidEnc = peerID.map { String(format: "%%%02X", $0) }.joined()
        let sep = url.contains("?") ? "&" : "?"
        let full = url + sep
            + "info_hash=\(hashEnc)&peer_id=\(pidEnc)&port=\(port)"
            + "&uploaded=0&downloaded=0&left=\(left)&compact=1&event=started&numwant=80"
        guard let u = URL(string: full) else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var peers: [PeerAddr] = []
            if let data = data, let root = try? BParser.parse(data), let dict = root.dictValue {
                peers = extractPeers(dict)
            }
            DispatchQueue.main.async { completion(peers) }
        }.resume()
    }

    static func extractPeers(_ dict: [String: BValue]) -> [PeerAddr] {
        var peers: [PeerAddr] = []
        if let compact = dict["peers"]?.dataValue {
            let b = [UInt8](compact)
            var i = 0
            while i + 6 <= b.count {
                let ip = "\(b[i]).\(b[i + 1]).\(b[i + 2]).\(b[i + 3])"
                let p = (UInt16(b[i + 4]) << 8) | UInt16(b[i + 5])
                if p > 0, b[i] != 0 {
                    peers.append(PeerAddr(host: ip, port: p))
                }
                i += 6
            }
        } else if let list = dict["peers"]?.listValue {
            for item in list {
                if let ip = item["ip"]?.stringValue,
                   let port = item["port"]?.intValue,
                   port > 0 {
                    peers.append(PeerAddr(host: ip, port: UInt16(clamping: port)))
                }
            }
        }
        return peers
    }
}

// MARK: - UDP tracker (BEP 15)

final class UDPAnnounce {

    static func run(url: String,
                    infoHash: Data,
                    peerID: Data,
                    port: UInt16,
                    left: Int,
                    completion: @escaping ([PeerAddr]) -> Void) {
        guard let comp = URLComponents(string: url),
              let host = comp.host,
              let p = comp.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: p)) else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        var finished = false
        var connectionID: UInt64 = 0

        func finish(_ peers: [PeerAddr]) {
            if finished { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async { completion(peers) }
        }

        let txConnect: UInt32 = UInt32.random(in: 1...0xFFFFFFF0)

        conn.stateUpdateHandler = { state in
            if case .ready = state {
                var d = Data()
                d.append(contentsOf: [0x00, 0x00, 0x04, 0x17, 0x27, 0x10, 0x19, 0x80])
                d.append(contentsOf: [0, 0, 0, 0])
                d.append(be32(txConnect))
                conn.send(content: d, completion: .contentProcessed { _ in })
            }
        }

        let txAnnounce: UInt32 = txConnect &+ 1

        func recv() {
            conn.receiveMessage { data, _, _, _ in
                guard let data = data, data.count >= 8 else {
                    finish([])
                    return
                }
                let b = [UInt8](data)
                let action = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
                if action == 0 && data.count >= 16 {
                    connectionID = be64(data, 8)
                    var d = Data()
                    d.append(be64(connectionID))
                    d.append(be32(1))
                    d.append(be32(txAnnounce))
                    d.append(infoHash)
                    d.append(peerID)
                    d.append(be64(0))
                    d.append(be64(UInt64(max(left, 0))))
                    d.append(be64(0))
                    d.append(be32(2))
                    d.append(be32(0))
                    d.append(be32(0))
                    d.append(be32(UInt32.random(in: 1...0xFFFFFFF0)))
                    d.append(be32(80))
                    d.append(be16(port))
                    conn.send(content: d, completion: .contentProcessed { _ in })
                    recv()
                } else if action == 1 && data.count >= 20 {
                    var peers: [PeerAddr] = []
                    var i = 20
                    while i + 6 <= b.count {
                        let ip = "\(b[i]).\(b[i + 1]).\(b[i + 2]).\(b[i + 3])"
                        let pp = (UInt16(b[i + 4]) << 8) | UInt16(b[i + 5])
                        if pp > 0, b[i] != 0 {
                            peers.append(PeerAddr(host: ip, port: pp))
                        }
                        i += 6
                    }
                    finish(peers)
                } else {
                    finish([])
                }
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { finish([]) }
        conn.start(queue: .global(qos: .userInitiated))
        recv()
    }

    // MARK: 字节工具

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func be16(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func be64(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((v >> UInt64(shift)) & 0xFF))
        }
        return out
    }

    static func be64(_ d: Data, _ offset: Int) -> UInt64 {
        let b = [UInt8](d)
        var v: UInt64 = 0
        var i = offset
        while i < offset + 8 && i < b.count {
            v = (v << 8) | UInt64(b[i])
            i += 1
        }
        return v
    }
}
