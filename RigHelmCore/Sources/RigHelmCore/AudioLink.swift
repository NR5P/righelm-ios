// The network side of a RigHelm `AUDIO` session: receives the radio's audio
// as 20 ms PCM frames over UDP and sends microphone frames back. The TCP
// connection only carries a heartbeat; the session lives while it does.

import Foundation

public struct AudioLinkStats: Equatable, Sendable {
    public var connected = false
    public var server = ""
    public var rate = RemoteProtocol.audioRate
    public var packets: UInt64 = 0
    public var lost: UInt64 = 0
    public var rxLevelDb: Float = -100
    public var micPackets: UInt64 = 0
    public var error: String?
    public init() {}
}

public final class AudioLink {
    public let host: String
    public let port: UInt16
    private let password: String

    /// Radio audio, called on the network thread: samples and the number of
    /// frames lost just before them.
    public var onAudio: (([Int16], Int) -> Void)?
    public var callbackQueue: DispatchQueue = .main
    /// About four times a second.
    public var onStats: ((AudioLinkStats) -> Void)?

    private let lock = NSLock()
    private var stopRequested = false
    private var started = false
    private var udp: UDPSocket?
    private var session: UInt64 = 0
    private var serverIP: UInt32 = 0
    private var serverPort: UInt16 = 0
    private var txSeq: UInt32 = 0
    private var stats = AudioLinkStats()

    public init(host: String, port: UInt16 = RemoteProtocol.controlPort, password: String) {
        (self.host, self.port, self.password) = (host, port, password)
    }

    public func start() {
        let go = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard go else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "righelm-audio"
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func stop() {
        lock.withLock { stopRequested = true }
    }

    public var currentStats: AudioLinkStats { lock.withLock { stats } }

    /// Send one microphone frame to the radio. The caller decides when
    /// (only while this operator transmits in a phone mode); the server
    /// checks again before playing it into the radio.
    public func sendMic(_ samples: [Int16]) {
        lock.lock()
        guard let udp, session != 0 else {
            lock.unlock()
            return
        }
        txSeq &+= 1
        let packet = AudioPacket.encode(kind: AudioPacket.tx, session: session, seq: txSeq, samples: samples)
        let (ip, port) = (serverIP, serverPort)
        stats.micPackets += 1
        lock.unlock()
        udp.send(packet, to: ip, port: port)
    }

    private var shouldStop: Bool { lock.withLock { stopRequested } }

    private func run() {
        while !shouldStop {
            do {
                try runSession()
            } catch {
                lock.withLock {
                    stats.connected = false
                    stats.error = String(describing: error)
                }
                publish()
            }
            let deadline = Date().addingTimeInterval(3)
            while !shouldStop && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }
        lock.withLock {
            udp = nil
            session = 0
            stats.connected = false
        }
        publish()
    }

    private func runSession() throws {
        let hs = try Handshake.open(host: host, port: port, password: password, mode: "AUDIO")
        let control = hs.socket
        defer { control.close() }
        let sock = try UDPSocket()
        defer {
            lock.withLock {
                udp = nil
                session = 0
            }
            sock.close()
        }
        let ip = try resolveIPv4(hs.peerIP)
        lock.withLock {
            udp = sock
            session = hs.session
            serverIP = ip
            serverPort = hs.udpPort
            stats = AudioLinkStats()
            stats.connected = true
            stats.server = hs.serverName
            stats.rate = hs.rate
        }
        publish()
        let hello = AudioPacket.encode(kind: AudioPacket.hello, session: hs.session, seq: 0, samples: [])
        var lastHello = Date.distantPast
        var lastPublish = Date()
        var lastSeq: UInt32?
        while !shouldStop {
            if Date().timeIntervalSince(lastHello) > 1 {
                sock.send(hello, to: ip, port: hs.udpPort)
                try control.write("\n")
                // The server never writes on this connection; anything read
                // here means it closed (read throws) or misbehaves.
                _ = try control.read(timeout: 0)
                lastHello = Date()
            }
            if Date().timeIntervalSince(lastPublish) > 0.25 {
                lastPublish = Date()
                publish()
            }
            guard let (bytes, from, _) = sock.receive(timeout: 0.1), from == ip,
                  let pkt = AudioPacket.decode(bytes), pkt.kind == AudioPacket.rx, pkt.session == hs.session
            else { continue }
            var lost = 0
            if let l = lastSeq {
                // A late duplicate or reordered packet: too late to play.
                if pkt.seq <= l && l &- pkt.seq < 1000 { continue }
                lost = Int(pkt.seq &- l &- 1)
                if lost > 1000 { lost = 0 }
            }
            lastSeq = pkt.seq
            let level = levelDbfs(pkt.samples)
            lock.withLock {
                stats.packets += 1
                stats.lost += UInt64(lost)
                stats.rxLevelDb = level
            }
            onAudio?(pkt.samples, lost)
        }
    }

    private func publish() {
        let s = currentStats
        callbackQueue.async { [weak self] in self?.onStats?(s) }
    }
}

/// RMS level of a frame in dBFS (-100 for silence).
public func levelDbfs(_ frame: [Int16]) -> Float {
    guard !frame.isEmpty else { return -100 }
    var sum: Double = 0
    for s in frame { sum += Double(s) * Double(s) }
    let rms = (sum / Double(frame.count)).squareRoot() / 32768
    return rms <= 1e-5 ? -100 : Float(20 * log10(rms))
}
