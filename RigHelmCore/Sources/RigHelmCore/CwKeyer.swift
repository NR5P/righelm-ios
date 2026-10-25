// CW from the phone: a straight key or iambic paddles and typed text, keyed
// in real time over a RigHelm `KEY` session (a port of righelm's
// crates/ftdx3000-rig/src/cw.rs).
//
// The timing is made here and the station keys its radio's port as told:
// `D` = down, `U` = up, `.` = still here. While held, `D` is repeated; the
// station lets go if it stops hearing from us (1.5 s) or the key stays down
// longer than 6 s.

import Foundation

public enum KeyerMode: String, CaseIterable, Identifiable, Sendable {
    /// Key down while held.
    case straight
    /// Iambic paddles without element memory past the squeeze.
    case iambicA
    /// Iambic paddles: a squeeze released mid-element adds the opposite one.
    case iambicB

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .straight: return "Straight key"
        case .iambicA: return "Iambic A"
        case .iambicB: return "Iambic B"
        }
    }
}

/// The keying output.
public protocol KeyLine: AnyObject {
    func set(_ down: Bool) throws
    /// Called a few times a second, so a remote end knows we're still here.
    func keepalive(_ down: Bool) throws
    /// Let go and close.
    func close()
}

// MARK: - Remote

/// Keys a RigHelm station's radio over a `KEY` session.
public final class RemoteKeyLine: KeyLine {
    private let socket: TCPSocket

    /// Opens the session; the station arms its keying port, then answers
    /// `READY` (or `ERR why`).
    public init(host: String, port: UInt16 = RemoteProtocol.controlPort, password: String) throws {
        let hs = try Handshake.open(host: host, port: port, password: password, mode: "KEY")
        socket = hs.socket
        do {
            let reply = try socket.readLine(timeout: 6)
            if reply == "READY" { return }
            if reply.hasPrefix("ERR ") { throw RemoteError.denied(String(reply.dropFirst(4))) }
            throw RemoteError.unexpected(reply)
        } catch {
            socket.close()
            throw error
        }
    }

    public func set(_ down: Bool) throws {
        try socket.write(down ? "D" : "U")
    }

    public func keepalive(_ down: Bool) throws {
        try socket.write(down ? "D" : ".")
        // The station never writes after READY; a read here only notices
        // that it closed (it throws).
        _ = try socket.read(timeout: 0)
    }

    public func close() {
        try? socket.write("U")
        socket.close()
    }
}

// MARK: - Keyer

public enum KeyerInput: Equatable, Sendable {
    /// Straight key (or either paddle in straight mode) pressed/released.
    case straight(Bool)
    /// Paddle state.
    case paddles(dit: Bool, dah: Bool)
    /// Send this text.
    case text(String)
    /// Stop sending and let go of the key.
    case stop
}

public struct CwStatus: Equatable, Sendable {
    /// The key line is open and the keyer takes input.
    public var ready = false
    public var down = false
    /// Typed text is being sent.
    public var sendingText = false
    public var error: String?
    public var note: String?
    public init() {}
}

/// The armed keyer, on its own thread. `stop()` lets go of the key and
/// closes the line; the thread keeps the keyer alive until then.
public final class CwKeyer {
    /// Longest continuous key-down before the keyer lets go by itself.
    public static let maxKeyDown: TimeInterval = 6
    /// Disarm after this long without keying.
    public static let idleDisarm: TimeInterval = 600

    private let cond = NSCondition()
    private var queue: [KeyerInput] = []
    private var stopped = false
    private var wpmValue: Int
    private var statusValue = CwStatus()
    private var lastActivity = now()
    public let armedAt = now()
    /// Called on the keyer thread whenever the key goes down or up (for a
    /// sidetone).
    private let onKey: ((Bool) -> Void)?

    /// `open` runs on the keyer thread (it may take a moment).
    public init(mode: KeyerMode, wpm: Int, onKey: ((Bool) -> Void)? = nil, open: @escaping () throws -> KeyLine) {
        wpmValue = min(max(wpm, 4), 60)
        self.onKey = onKey
        let t = Thread { [self] in self.thread(mode: mode, open: open) }
        t.name = "righelm-cw-keyer"
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func input(_ i: KeyerInput) {
        cond.withLock {
            queue.append(i)
            cond.signal()
        }
    }

    public func setWPM(_ wpm: Int) {
        cond.withLock { wpmValue = min(max(wpm, 4), 60) }
    }

    public var status: CwStatus { cond.withLock { statusValue } }

    /// Seconds since the operator last keyed.
    public var idleFor: TimeInterval { now() - cond.withLock { lastActivity } }

    public func stop() {
        cond.withLock {
            stopped = true
            queue.append(.stop)
            cond.signal()
        }
    }

    private func update(_ change: (inout CwStatus) -> Void) {
        cond.withLock { change(&statusValue) }
    }

    private func thread(mode: KeyerMode, open: () throws -> KeyLine) {
        let line: KeyLine
        do {
            line = try open()
        } catch {
            update { $0.error = String(describing: error) }
            return
        }
        // Stopped while the line was opening.
        if cond.withLock({ stopped }) {
            line.close()
            return
        }
        update { $0.ready = true }
        var k = Keyer(line: line, status: { self.update($0) }, onKey: onKey)
        do {
            try run(&k, mode: mode)
        } catch {
            update { $0.error = "keying stopped: \(error)" }
        }
        try? k.key(false)
        line.close()
        onKey?(false)
        update {
            $0.ready = false
            $0.down = false
        }
    }

    /// Next input, or nil once `deadline` passes. Also says whether to stop.
    private func next(until deadline: TimeInterval) -> (KeyerInput?, Bool) {
        cond.lock()
        defer { cond.unlock() }
        while queue.isEmpty && !stopped {
            let left = deadline - now()
            if left <= 0 || !cond.wait(until: Date(timeIntervalSinceNow: left)) { break }
        }
        let input = queue.isEmpty ? nil : queue.removeFirst()
        if input != nil { lastActivity = now() }
        return (input, stopped)
    }

    private func run(_ k: inout Keyer, mode: KeyerMode) throws {
        // Timed key states still to play: (down, length in dits).
        var plan: [(Bool, Int)] = []
        var textPlan = false // `plan` holds typed text
        var until: TimeInterval?
        var (ditHeld, dahHeld, ditMem, dahMem) = (false, false, false, false)
        var lastDah = false
        var lastKeepalive = now()
        while true {
            let (input, stop) = next(until: until ?? now() + 0.1)
            if stop { break }
            if let input {
                switch input {
                case .straight(let d):
                    if mode == .straight {
                        plan.removeAll()
                        until = nil
                        try k.key(d)
                    }
                case .paddles(let dit, let dah):
                    if mode == .straight {
                        plan.removeAll()
                        until = nil
                        try k.key(dit || dah)
                    } else {
                        if textPlan && (dit || dah) {
                            // Touching the paddles interrupts typed text.
                            plan.removeAll()
                            textPlan = false
                            until = nil
                            try k.key(false)
                        }
                        ditMem = ditMem || (dit && !ditHeld)
                        dahMem = dahMem || (dah && !dahHeld)
                        (ditHeld, dahHeld) = (dit, dah)
                    }
                case .text(let t):
                    if plan.isEmpty || textPlan {
                        plan += morsePlan(t)
                        textPlan = true
                    }
                case .stop:
                    plan.removeAll()
                    until = nil
                    (ditMem, dahMem, ditHeld, dahHeld) = (false, false, false, false)
                    try k.key(false)
                }
            }
            let t = now()
            if t - lastKeepalive > 0.4 {
                try k.line.keepalive(k.down)
                lastKeepalive = t
            }
            if let u = until, t < u { continue }
            until = nil
            if plan.isEmpty {
                textPlan = false
                if mode != .straight && !k.down {
                    // Mode A forgets a paddle let go during the last element.
                    if mode == .iambicA {
                        (ditMem, dahMem) = (false, false)
                    }
                    let (dit, dah) = (ditMem || ditHeld, dahMem || dahHeld)
                    var nextDah: Bool?
                    switch (dit, dah) {
                    case (true, true): nextDah = !lastDah
                    case (true, false): nextDah = false
                    case (false, true): nextDah = true
                    default: nextDah = nil
                    }
                    if let d = nextDah {
                        if d { dahMem = false } else { ditMem = false }
                        lastDah = d
                        plan.append((true, d ? 3 : 1))
                        plan.append((false, 1))
                        cond.withLock { lastActivity = t }
                    }
                }
            }
            if !plan.isEmpty {
                let (down, dits) = plan.removeFirst()
                try k.key(down)
                let dit = 1.2 / Double(cond.withLock { wpmValue })
                until = t + dit * Double(dits)
            }
            if k.down && t - k.downSince > Self.maxKeyDown {
                plan.removeAll()
                until = nil
                try k.key(false)
                update { $0.note = "key held too long: released" }
            }
            let sending = textPlan
            update { if $0.sendingText != sending { $0.sendingText = sending } }
        }
    }
}

private struct Keyer {
    let line: KeyLine
    let status: ((inout CwStatus) -> Void) -> Void
    let onKey: ((Bool) -> Void)?
    var down = false
    var downSince = now()

    mutating func key(_ d: Bool) throws {
        guard d != down else { return }
        try line.set(d)
        down = d
        if d { downSince = now() }
        onKey?(d)
        status { $0.down = d }
    }
}

/// Monotonic seconds.
private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

// MARK: - Morse

/// Morse for one character, `.` and `-`.
public func morse(_ c: Character) -> String? {
    switch c.uppercased() {
    case "A": return ".-"
    case "B": return "-..."
    case "C": return "-.-."
    case "D": return "-.."
    case "E": return "."
    case "F": return "..-."
    case "G": return "--."
    case "H": return "...."
    case "I": return ".."
    case "J": return ".---"
    case "K": return "-.-"
    case "L": return ".-.."
    case "M": return "--"
    case "N": return "-."
    case "O": return "---"
    case "P": return ".--."
    case "Q": return "--.-"
    case "R": return ".-."
    case "S": return "..."
    case "T": return "-"
    case "U": return "..-"
    case "V": return "...-"
    case "W": return ".--"
    case "X": return "-..-"
    case "Y": return "-.--"
    case "Z": return "--.."
    case "0": return "-----"
    case "1": return ".----"
    case "2": return "..---"
    case "3": return "...--"
    case "4": return "....-"
    case "5": return "....."
    case "6": return "-...."
    case "7": return "--..."
    case "8": return "---.."
    case "9": return "----."
    case ".": return ".-.-.-"
    case ",": return "--..--"
    case "?": return "..--.."
    case "/": return "-..-."
    case "=": return "-...-"
    case "+": return ".-.-."
    case "-": return "-....-"
    case "(": return "-.--."
    case ")": return "-.--.-"
    case "'": return ".----."
    case "\"": return ".-..-."
    case ":": return "---..."
    case "@": return ".--.-."
    case "!": return "-.-.--"
    default: return nil
    }
}

/// Key states for `text`: (down, dits). Element gap 1, letter gap 3, word gap 7.
public func morsePlan(_ text: String) -> [(Bool, Int)] {
    var out: [(Bool, Int)] = []
    var gap = 0
    for c in text {
        if c.isWhitespace {
            gap = 7
            continue
        }
        guard let code = morse(c) else { continue }
        if !out.isEmpty {
            out.append((false, max(gap, 3)))
        }
        for (i, e) in code.enumerated() {
            if i > 0 { out.append((false, 1)) }
            out.append((true, e == "-" ? 3 : 1))
        }
        gap = 3
    }
    if !out.isEmpty { out.append((false, 3)) }
    return out
}
