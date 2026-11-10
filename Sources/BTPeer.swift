import Foundation
import Network

// MARK: - 单条 peer 连接

final class PeerLink {

    let addr: PeerAddr
    private let infoHash: Data
    private let peerID: Data

    private var conn: NWConnection?
    private var buf: [UInt8] = []
    private var gotHandshake = false
    private var closed = false

    var peerMetaID: Int?
    var choked = true
    var onConnected: (() -> Void)?
    var onExtended: ((Int, Data) -> Void)?
    var onMessage: ((UInt8, [UInt8]) -> Void)?
    var onClose: (() -> Void)?

    init(addr: PeerAddr, infoHash: Data, peerID: Data) {
        self.addr = addr
        self.infoHash = infoHash
        self.peerID = peerID
    }

    func start() {
        guard let port = NWEndpoint.Port(rawValue: addr.port) else {
            close()
            return
        }
        let c = NWConnection(host: NWEndpoint.Host(addr.host), port: port, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendHandshake()
                DispatchQueue.main.async {
                    self.onConnected?()
                }
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        c.start(queue: DispatchQueue.global(qos: .userInitiated))
        pump(c)
    }

    private func pump(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.buf.append(contentsOf: d)
                self.drain()
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            self.pump(c)
        }
    }

    private func drain() {
        while true {
            if !gotHandshake {
                if buf.count < 68 { return }
                if Int(buf[0]) != 19 {
                    close()
                    return
                }
                gotHandshake = true
                buf.removeFirst(68)
                sendExtensionHandshake()
                sendMessage(2, [])
                continue
            }
            if buf.count < 4 { return }
            let len = (Int(buf[0]) << 24) | (Int(buf[1]) << 16) | (Int(buf[2]) << 8) | Int(buf[3])
            if len <= 0 || len > 2_000_000 {
                close()
                return
            }
            if buf.count < 4 + len { return }
            let payload = Array(buf[4..<(4 + len)])
            buf.removeFirst(4 + len)
            guard let id = payload.first else { continue }
            let body = Array(payload.dropFirst())
            if id == 20 {
                if let extID = body.first {
                    let rest = Data(body.dropFirst())
                    onExtended?(Int(extID), rest)
                }
            } else {
                onMessage?(id, body)
            }
        }
    }

    func sendBytes(_ bytes: [UInt8]) {
        conn?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func sendMessage(_ id: UInt8, _ payload: [UInt8]) {
        var msg: [UInt8] = [0, 0, 0, 0, id]
        msg.append(contentsOf: payload)
        let total = msg.count - 4
        msg[0] = UInt8((total >> 24) & 0xFF)
        msg[1] = UInt8((total >> 16) & 0xFF)
        msg[2] = UInt8((total >> 8) & 0xFF)
        msg[3] = UInt8(total & 0xFF)
        sendBytes(msg)
    }

    func sendExtension(_ extID: UInt8, _ payload: [UInt8]) {
        sendMessage(20, [extID] + payload)
    }

    private func sendHandshake() {
        var d: [UInt8] = [19]
        d.append(contentsOf: Array("BitTorrent protocol".utf8))
        d.append(contentsOf: [0, 0, 0, 0, 0, 0x10, 0, 0])
        d.append(contentsOf: infoHash)
        d.append(contentsOf: peerID)
        sendBytes(d)
    }

    private func sendExtensionHandshake() {
        let body = Array("d1:md11:ut_metadatai1eee1:v10:DSHbrowsere".utf8)
        sendMessage(20, [UInt8(0)] + body)
    }

    func close() {
        if closed { return }
        closed = true
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        DispatchQueue.main.async {
            self.onClose?()
        }
    }
}
