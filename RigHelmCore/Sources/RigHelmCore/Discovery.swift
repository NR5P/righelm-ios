// Finds RigHelm servers on the LAN.
//
// Servers broadcast a beacon every 2 s on UDP 4534 and answer a
// `FTDX3000-DISCOVER` probe sent to that port. iOS only lets an app send
// and receive broadcasts with Apple's multicast entitlement, so besides
// broadcasting, the probe also goes straight to every address on the local
// subnet: the answers are ordinary unicast and need no entitlement.

import Foundation

public final class Discovery {
    /// Called on `callbackQueue` whenever the list changes.
    public var onUpdate: (([ServerBeacon]) -> Void)?
    public var callbackQueue: DispatchQueue = .main

    private let lock = NSLock()
    private var running = false
    private var found: [String: ServerBeacon] = [:]
    private var probeRequested = false
    /// Bumped by every start, so a stopped thread can't come back to life.
    private var generation = 0

    public init() {}

    public var servers: [ServerBeacon] {
        lock.withLock { Array(found.values) }.sorted { $0.name < $1.name }
    }

    public func start() {
        let gen = lock.withLock { () -> Int? in
            guard !running else { return nil }
            running = true
            generation += 1
            return generation
        }
        guard let gen else { return }
        let t = Thread { [weak self] in self?.run(gen) }
        t.name = "righelm-discovery"
        t.start()
    }

    public func stop() {
        lock.withLock { running = false }
    }

    /// Probe again right away (e.g. on pull-to-refresh).
    public func probeNow() {
        lock.withLock { probeRequested = true }
    }

    private func isRunning(_ gen: Int) -> Bool { lock.withLock { running && generation == gen } }

    private func run(_ gen: Int) {
        // Port 4534 also catches beacons where broadcasts are allowed; when
        // another program holds it, any port gets the probe answers.
        guard let sock = (try? UDPSocket(port: RemoteProtocol.discoveryPort, reusePort: true, broadcast: true))
            ?? (try? UDPSocket(port: 0, broadcast: true))
        else { return }
        defer { sock.close() }
        var lastProbe = Date.distantPast
        var probes = 0
        while isRunning(gen) {
            // Quickly at first, then every 5 s.
            let every: TimeInterval = probes < 3 ? 1.5 : 5
            let asked = lock.withLock { () -> Bool in
                defer { probeRequested = false }
                return probeRequested
            }
            if asked || Date().timeIntervalSince(lastProbe) > every {
                sendProbes(sock)
                lastProbe = Date()
                probes += 1
            }
            if let (bytes, ip, _) = sock.receive(timeout: 0.25),
               let beacon = ServerBeacon.parse(String(decoding: bytes, as: UTF8.self), from: ipString(ip)) {
                lock.withLock { found[beacon.id] = beacon }
                publish()
            }
            let expired = lock.withLock { () -> Bool in
                let before = found.count
                found = found.filter { Date().timeIntervalSince($0.value.lastSeen) < 12 }
                return found.count != before
            }
            if expired { publish() }
        }
    }

    private func sendProbes(_ sock: UDPSocket) {
        let port = RemoteProtocol.discoveryPort
        sock.send(RemoteProtocol.probe, to: 0xFFFF_FFFF, port: port)
        for iface in lanInterfaces() {
            sock.send(RemoteProtocol.probe, to: iface.broadcast, port: port)
            for host in Discovery.sweep(iface) {
                sock.send(RemoteProtocol.probe, to: host, port: port)
            }
        }
    }

    /// Every other host on the interface's subnet; for a subnet bigger than
    /// /22, just the /24 around this device.
    static func sweep(_ iface: NetInterface) -> [UInt32] {
        var mask = iface.netmask
        if mask < 0xFFFF_FC00 { mask = 0xFFFF_FF00 }
        let net = iface.address & mask
        let bcast = net | ~mask
        guard bcast > net + 1 else { return [] }
        return (net + 1..<bcast).filter { $0 != iface.address }
    }

    private func publish() {
        let list = servers
        callbackQueue.async { [weak self] in self?.onUpdate?(list) }
    }
}
