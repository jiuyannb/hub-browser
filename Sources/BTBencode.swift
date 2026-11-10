import Foundation

// MARK: - Bencode

indirect enum BValue {
    case int(Int)
    case str(Data)
    case list([BValue])
    case dict([String: BValue])

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var dataValue: Data? {
        if case .str(let d) = self { return d }
        return nil
    }

    var stringValue: String? {
        if case .str(let d) = self { return String(decoding: d, as: UTF8.self) }
        return nil
    }

    var listValue: [BValue]? {
        if case .list(let l) = self { return l }
        return nil
    }

    var dictValue: [String: BValue]? {
        if case .dict(let d) = self { return d }
        return nil
    }

    subscript(key: String) -> BValue? {
        dictValue?[key]
    }
}

enum BencodeError: Error {
    case bad
}

struct BParser {
    private let bytes: [UInt8]
    private var i = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    static func parse(_ data: Data) throws -> BValue {
        var p = BParser(data)
        return try p.parseOne()
    }

    static func parsePrefix(_ data: Data) -> (BValue, Int)? {
        var p = BParser(data)
        guard let v = try? p.parseOne() else { return nil }
        return (v, p.i)
    }

    private mutating func parseOne() throws -> BValue {
        guard i < bytes.count else { throw BencodeError.bad }
        let c = bytes[i]
        if c == 0x69 {
            i += 1
            var s = ""
            while i < bytes.count && bytes[i] != 0x65 {
                s.append(String(UnicodeScalar(bytes[i])))
                i += 1
            }
            guard i < bytes.count else { throw BencodeError.bad }
            i += 1
            guard let v = Int(s) else { throw BencodeError.bad }
            return .int(v)
        }
        if c == 0x6C {
            i += 1
            var arr: [BValue] = []
            while i < bytes.count && bytes[i] != 0x65 {
                arr.append(try parseOne())
            }
            guard i < bytes.count else { throw BencodeError.bad }
            i += 1
            return .list(arr)
        }
        if c == 0x64 {
            i += 1
            var dict: [String: BValue] = [:]
            while i < bytes.count && bytes[i] != 0x65 {
                let k = try parseOne()
                guard let kd = k.dataValue else { throw BencodeError.bad }
                let key = String(decoding: kd, as: UTF8.self)
                dict[key] = try parseOne()
            }
            guard i < bytes.count else { throw BencodeError.bad }
            i += 1
            return .dict(dict)
        }
        if c >= 0x30 && c <= 0x39 {
            var s = ""
            while i < bytes.count && bytes[i] != 0x3A {
                s.append(String(UnicodeScalar(bytes[i])))
                i += 1
            }
            guard i < bytes.count else { throw BencodeError.bad }
            i += 1
            guard let n = Int(s), n >= 0, i + n <= bytes.count else { throw BencodeError.bad }
            let sub = Data(bytes[i..<(i + n)])
            i += n
            return .str(sub)
        }
        throw BencodeError.bad
    }
}

// MARK: - Magnet

struct MagnetInfo {
    var infoHash: Data
    var name: String
    var trackers: [String]

    static func parse(_ raw: String) -> MagnetInfo? {
        guard raw.lowercased().hasPrefix("magnet:") else { return nil }
        var hash: Data?
        var name = "torrent"
        var trackers: [String] = []

        let body = String(raw.dropFirst("magnet:?".count))
        for pair in body.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count >= 2 else { continue }
            let k = kv[0]
            let v = kv.dropFirst().joined(separator: "=")
            let decoded = v.removingPercentEncoding ?? v
            if k == "xt" {
                if let r = decoded.range(of: "urn:btih:") {
                    let hex = String(decoded[r.upperBound...]).uppercased()
                    if hex.count == 40 {
                        hash = Data.fromHex(hex)
                    } else if hex.count == 32 {
                        hash = Data.fromBase32(hex)
                    }
                }
            } else if k == "dn" {
                name = decoded
            } else if k == "tr" {
                if !decoded.isEmpty { trackers.append(decoded) }
            }
        }
        guard let h = hash, h.count == 20 else { return nil }
        return MagnetInfo(infoHash: h, name: name, trackers: trackers)
    }
}

extension Data {
    static func fromHex(_ s: String) -> Data? {
        var out = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            let part = String(s[idx..<next])
            guard let b = UInt8(part, radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    static func fromBase32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var out = Data()
        for ch in s.uppercased() {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Peer 地址

struct PeerAddr: Hashable {
    var host: String
    var port: UInt16
}
