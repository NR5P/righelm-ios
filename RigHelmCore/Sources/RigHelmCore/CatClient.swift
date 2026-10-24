// Controls a remote radio over a RigHelm `CAT` session: keeps a copy of
// the radio's state up to date (auto-information plus polling, like
// righelm's own engine) and sends Set commands.
//
// Transmit safety: a Set that would transmit is dropped unless
// `isTransmitAllowed()` says yes, and the session un-keys before it closes.
// The server also un-keys a client that vanishes.

import Foundation

public final class CatClient {
    public enum Status: Equatable {
        case connecting
        case connected(server: String)
        /// The last attempt failed; retrying.
        case failed(String)
        case stopped
    }

    public let host: String
    public let port: UInt16
    private let password: String

    public var callbackQueue: DispatchQueue = .main
    public var onStatus: ((Status) -> Void)?
    public var onState: ((RadioState) -> Void)?
    public var onNote: ((String) -> Void)?
    /// Asked before any transmit command goes out.
    public var isTransmitAllowed: () -> Bool = { false }

    private let lock = NSLock()
    private var outbox: [String] = []
    private var stopRequested = false
    private var started = false
    private var keyed = false
    private var keyedAt = Date.distantPast
    private var latest = RadioState()

    public init(host: String, port: UInt16 = RemoteProtocol.controlPort, password: String) {
        (self.host, self.port, self.password) = (host, port, password)
    }

    /// This client keyed the transmitter (and has not let go). Microphone
    /// audio is only sent while this is true.
    public var keyedByUs: Bool { lock.withLock { keyed } }

    public var state: RadioState { lock.withLock { latest } }

    public func start() {
        let go = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard go else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "righelm-cat"
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// Un-keys if this client keyed, then closes.
    public func stop() {
        lock.withLock { stopRequested = true }
    }

    /// Queue Set (or Read) commands, e.g. "FA14074000;" or "AB;SV;".
    public func send(_ commands: String) {
        for f in CatCommand.frames(commands) {
            if CatCommand.isTransmit(f) && !isTransmitAllowed() {
                note("not sent: \(f) would transmit, and transmit is locked")
                continue
            }
            lock.withLock {
                outbox.append(f)
                if CatCommand.isTransmit(f) && (f.hasPrefix("TX") || f.hasPrefix("MX")) {
                    keyed = true
                    keyedAt = Date()
                } else if CatCommand.isUnkey(f) {
                    keyed = false
                }
            }
        }
    }

    private var shouldStop: Bool { lock.withLock { stopRequested } }

    private func run() {
        while !shouldStop {
            report(.connecting)
            do {
                try session()
            } catch {
                report(.failed(String(describing: error)))
            }
            // Wait before retrying; a wrong password won't get better by itself.
            let deadline = Date().addingTimeInterval(3)
            while !shouldStop && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }
        report(.stopped)
    }

    private struct Poll {
        var cmd: String
        var every: TimeInterval
        var next: Date
        /// nil = always; true = only transmitting; false = only receiving.
        var whenTX: Bool?
    }

    private func session() throws {
        let hs = try Handshake.open(host: host, port: port, password: password, mode: "CAT")
        let sock = hs.socket
        defer { sock.close() }
        report(.connected(server: hs.serverName))
        note("connected to \"\(hs.serverName)\" at \(host)")

        var state = RadioState()
        var framer = Framer()
        let now = Date()
        var polls: [Poll] = [Poll(cmd: "TX;", every: 0.25, next: now, whenTX: nil),
                             Poll(cmd: "SM0;", every: 0.15, next: now, whenTX: false)]
        for m in ["RM5;", "RM6;", "RM4;", "RM3;"] {
            polls.append(Poll(cmd: m, every: 0.15, next: now, whenTX: true))
        }
        polls.append(Poll(cmd: "RM8;", every: 2, next: now, whenTX: true))
        for v in CatCommand.vfoPoll {
            polls.append(Poll(cmd: v, every: 3, next: now.addingTimeInterval(3), whenTX: nil))
        }
        for (i, m) in CatCommand.miscPoll.enumerated() {
            polls.append(Poll(cmd: m, every: 15, next: now.addingTimeInterval(1 + Double(i) * 0.25), whenTX: nil))
        }
        // Read everything once, then turn on auto-information so changes
        // made at the station arrive straight away.
        var once: [String] = ["ID;", "PS;"] + CatCommand.vfoPoll + CatCommand.miscPoll
        var later: [(Date, String)] = []
        try sock.write("AI1;")

        var lastHeard = Date()
        var lastPublish = Date.distantPast
        var dirty = true
        while true {
            if shouldStop {
                let unkey = lock.withLock { () -> Bool in
                    defer { keyed = false }
                    return keyed
                }
                // Anything queued (such as a final TX0;) goes out first.
                let rest = lock.withLock { () -> [String] in
                    defer { outbox.removeAll() }
                    return outbox
                }.joined()
                try? sock.write(rest + (unkey ? "TX0;" : ""))
                Thread.sleep(forTimeInterval: 0.05)
                return
            }
            let bytes = try sock.read(timeout: 0.03)
            if !bytes.isEmpty {
                lastHeard = Date()
                for f in framer.push(bytes) where state.apply(f) {
                    dirty = true
                }
            }
            // The server answers polls several times a second.
            if Date().timeIntervalSince(lastHeard) > 6 {
                throw SocketError("the server stopped answering")
            }
            let now = Date()
            lock.withLock {
                // Let go of "keyed by us" once the radio is back on receive.
                if keyed && !state.transmitting && now.timeIntervalSince(keyedAt) > 2 {
                    keyed = false
                }
            }

            var out = ""
            let sets = lock.withLock { () -> [String] in
                defer { outbox.removeAll() }
                return outbox
            }
            for f in sets {
                out += f
                if f.count > 3 || !f.hasSuffix(";") {
                    // Show the change right away; the radio's answer confirms it.
                    if !CatCommand.isTransmit(f) && state.apply(f) { dirty = true }
                    if let rb = CatCommand.readback(for: f) { later.append((now.addingTimeInterval(0.3), rb)) }
                    // Keying: confirm it as soon as the radio has had time to switch.
                    if f.hasPrefix("TX") || f.hasPrefix("MX") {
                        later += [0.05, 0.12].map { (now.addingTimeInterval($0), "TX;") }
                    }
                    if CatCommand.movesVFO(f) {
                        later += CatCommand.vfoKeys.map { (now.addingTimeInterval(0.4), $0) }
                    }
                }
            }
            let tx = state.transmitting
            for i in polls.indices where polls[i].next <= now {
                if let w = polls[i].whenTX, w != tx { continue }
                out += polls[i].cmd
                polls[i].next = now.addingTimeInterval(polls[i].every)
            }
            for _ in 0..<min(8, once.count) {
                out += once.removeFirst()
            }
            let due = later.filter { $0.0 <= now }.map(\.1)
            later.removeAll { $0.0 <= now }
            for r in Set(due) { out += r }
            if !out.isEmpty {
                try sock.write(out)
            }

            if dirty && now.timeIntervalSince(lastPublish) > 0.06 {
                dirty = false
                lastPublish = now
                let snapshot = state
                lock.withLock { latest = snapshot }
                callbackQueue.async { [weak self] in self?.onState?(snapshot) }
            }
        }
    }

    private func report(_ s: Status) {
        callbackQueue.async { [weak self] in self?.onStatus?(s) }
    }

    private func note(_ text: String) {
        callbackQueue.async { [weak self] in self?.onNote?(text) }
    }
}
