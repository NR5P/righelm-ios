// RigHelm's LAN remote protocol, client side (see righelm's
// crates/ftdx3000-rig/src/remote.rs for the server).
//
// * Discovery (UDP 4534): servers broadcast a beacon every 2 s and answer
//   `FTDX3000-DISCOVER` probes.
// * Sessions (TCP 4533): the server greets with a nonce; the client proves
//   the password with HMAC-SHA256(password, "ftdx3000:<nonce>:<mode>").
//   - `CAT` sessions carry plain FTDX3000 CAT.
//   - `AUDIO` sessions keep TCP as a heartbeat and exchange 20 ms PCM
//     frames over UDP on the port the server names.

import CryptoKit
import Foundation

public enum RemoteProtocol {
    public static let controlPort: UInt16 = 4533
    public static let discoveryPort: UInt16 = 4534
    public static let audioRate = 24_000
    public static let greeting = "FTDX3000-REMOTE"
    public static let probe = Array("FTDX3000-DISCOVER".utf8)

    /// Samples in one 20 ms frame at `rate`.
    public static func frameLength(rate: Int) -> Int { rate / 50 }

    /// Proof of the password for one session: hex HMAC-SHA256.
    public static func proof(password: String, nonce: String, mode: String) -> String {
        // An open server ignores the proof; CryptoKit wants a non-empty key.
        if password.isEmpty { return "-" }
        let key = SymmetricKey(data: Data(password.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("ftdx3000:\(nonce):\(mode)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// A RigHelm server found on the LAN.
public struct ServerBeacon: Identifiable, Equatable, Sendable {
    /// The server's random per-process id (hex).
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var audio: Bool
    /// A password is set (and so transmit can be allowed).
    public var auth: Bool
    /// The server plays clients' microphones into the radio.
    public var mic: Bool
    /// The server's own radio link: "connected", "not-answering", "disconnected".
    public var radio: String
    public var lastSeen: Date

    public init(id: String, name: String, host: String, port: UInt16, audio: Bool, auth: Bool, mic: Bool, radio: String, lastSeen: Date = Date()) {
        (self.id, self.name, self.host, self.port) = (id, name, host, port)
        (self.audio, self.auth, self.mic, self.radio, self.lastSeen) = (audio, auth, mic, radio, lastSeen)
    }

    /// `FTDX3000-REMOTE v1;id=...;name=...;port=4533;audio=1;auth=1;mic=1;radio=connected`
    public static func parse(_ text: String, from host: String) -> ServerBeacon? {
        guard text.hasPrefix(RemoteProtocol.greeting) else { return nil }
        var parts = text.dropFirst(RemoteProtocol.greeting.count).trimmingCharacters(in: .whitespaces).split(separator: ";", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        parts.removeFirst() // version
        var f: [String: String] = [:]
        for p in parts {
            if let eq = p.firstIndex(of: "=") {
                f[String(p[..<eq])] = String(p[p.index(after: eq)...])
            }
        }
        guard let id = f["id"], UInt64(id, radix: 16) != nil, let port = f["port"].flatMap({ UInt16($0) }) else { return nil }
        return ServerBeacon(
            id: id, name: f["name"] ?? "?", host: host, port: port,
            audio: f["audio"] == "1", auth: f["auth"] == "1", mic: f["mic"] == "1", radio: f["radio"] ?? "?")
    }
}

/// UDP audio packet: "FX" ver=1 kind session:u64le seq:u32le, then s16le samples.
public enum AudioPacket {
    public static let hello: UInt8 = 1
    public static let rx: UInt8 = 2
    public static let tx: UInt8 = 3
    public static let headerSize = 16

    public static func encode(kind: UInt8, session: UInt64, seq: UInt32, samples: [Int16]) -> [UInt8] {
        var p = [UInt8]()
        p.reserveCapacity(headerSize + samples.count * 2)
        p += [0x46, 0x58, 1, kind] // "FX"
        withUnsafeBytes(of: session.littleEndian) { p += $0 }
        withUnsafeBytes(of: seq.littleEndian) { p += $0 }
        for s in samples {
            withUnsafeBytes(of: s.littleEndian) { p += $0 }
        }
        return p
    }

    public static func decode(_ p: [UInt8]) -> (kind: UInt8, session: UInt64, seq: UInt32, samples: [Int16])? {
        guard p.count >= headerSize, p[0] == 0x46, p[1] == 0x58, p[2] == 1 else { return nil }
        var session: UInt64 = 0
        var seq: UInt32 = 0
        for i in 0..<8 { session |= UInt64(p[4 + i]) << (8 * UInt64(i)) }
        for i in 0..<4 { seq |= UInt32(p[12 + i]) << (8 * UInt32(i)) }
        let n = (p.count - headerSize) / 2
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = Int16(bitPattern: UInt16(p[headerSize + 2 * i]) | UInt16(p[headerSize + 2 * i + 1]) << 8)
        }
        return (p[3], session, seq, samples)
    }
}

public enum RemoteError: Error, CustomStringConvertible, Equatable {
    case denied(String)
    case notRigHelm
    case unexpected(String)

    public var description: String {
        switch self {
        case .denied(let why): return why
        case .notRigHelm: return "that address is not a RigHelm server"
        case .unexpected(let line): return "unexpected reply: \(line)"
        }
    }

    public var isWrongPassword: Bool {
        if case .denied(let why) = self { return why.contains("password") }
        return false
    }
}

/// An authenticated session, positioned just after the server's `OK`.
public struct Handshake {
    public let socket: TCPSocket
    public let serverName: String
    public let session: UInt64
    public let udpPort: UInt16
    public let rate: Int
    public let peerIP: String

    public static func open(host: String, port: UInt16, password: String, mode: String) throws -> Handshake {
        let sock = try TCPSocket.connect(host: host, port: port, timeout: 4)
        do {
            let greet = try sock.readLine(timeout: 5).split(separator: " ").map(String.init)
            guard greet.count >= 3, greet[0] == RemoteProtocol.greeting else { throw RemoteError.notRigHelm }
            let nonce = greet[2]
            let name = greet.dropFirst(3).joined(separator: " ")
            try sock.write("HELLO \(mode) \(RemoteProtocol.proof(password: password, nonce: nonce, mode: mode))\n")
            let line = try sock.readLine(timeout: 5)
            let reply = line.split(separator: " ").map(String.init)
            switch reply.first {
            case "OK":
                let session = reply.count > 1 ? UInt64(reply[1], radix: 16) ?? 0 : 0
                let udp = reply.count > 2 ? UInt16(reply[2]) ?? port : port
                let rate = reply.count > 3 ? Int(reply[3]) ?? RemoteProtocol.audioRate : RemoteProtocol.audioRate
                guard (8_000...48_000).contains(rate) else { throw RemoteError.unexpected("audio rate \(rate)") }
                return Handshake(socket: sock, serverName: name, session: session, udpPort: udp, rate: rate, peerIP: sock.peerIP)
            case "DENIED":
                throw RemoteError.denied(String(line.dropFirst("DENIED ".count)))
            default:
                throw RemoteError.unexpected(line)
            }
        } catch {
            sock.close()
            throw error
        }
    }
}
