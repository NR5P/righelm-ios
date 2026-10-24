//! Small blocking BSD-socket wrappers, used from the client's own threads.

import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }

    static func last(_ what: String) -> SocketError {
        SocketError("\(what): \(String(cString: strerror(errno)))")
    }
}

extension sockaddr_in {
    init(ip: UInt32, port: UInt16) {
        self.init()
        sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin_family = sa_family_t(AF_INET)
        sin_port = port.bigEndian
        sin_addr = in_addr(s_addr: ip.bigEndian)
    }

    /// Host-order IPv4 address.
    var ip: UInt32 { UInt32(bigEndian: sin_addr.s_addr) }
    var port: UInt16 { UInt16(bigEndian: sin_port) }
}

public func ipString(_ ip: UInt32) -> String {
    "\(ip >> 24 & 0xff).\(ip >> 16 & 0xff).\(ip >> 8 & 0xff).\(ip & 0xff)"
}

/// Resolve `host` to a host-order IPv4 address.
public func resolveIPv4(_ host: String) throws -> UInt32 {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, nil, &hints, &res)
    guard rc == 0, let ai = res, let sa = ai.pointee.ai_addr else {
        throw SocketError("cannot find \(host): \(String(cString: gai_strerror(rc)))")
    }
    defer { freeaddrinfo(res) }
    return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.ip }
}

private func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
    var v = value
    setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
}

private func waitFor(_ fd: Int32, _ events: Int32, timeout: TimeInterval) -> Int32 {
    var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
    return poll(&pfd, 1, Int32(max(0, timeout) * 1000))
}

// MARK: - TCP

public final class TCPSocket {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    /// Received but not yet consumed (after a `readLine`).
    private var pending: [UInt8] = []
    public let peerIP: String

    private init(fd: Int32, peerIP: String) {
        self.fd = fd
        self.peerIP = peerIP
    }

    deinit { close() }

    public static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> TCPSocket {
        let ip = try resolveIPv4(host)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        setOption(fd, Int32(IPPROTO_TCP), TCP_NODELAY, 1)
        setOption(fd, SOL_SOCKET, SO_KEEPALIVE, 1)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in(ip: ip, port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else {
                let e = SocketError.last("cannot connect to \(host):\(port)")
                Darwin.close(fd)
                throw e
            }
            if waitFor(fd, POLLOUT, timeout: timeout) <= 0 {
                Darwin.close(fd)
                throw SocketError("no answer from \(host):\(port)")
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 {
                Darwin.close(fd)
                throw SocketError("cannot connect to \(host):\(port): \(String(cString: strerror(err)))")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return TCPSocket(fd: fd, peerIP: ipString(ip))
    }

    /// Bytes that arrive within `timeout`; empty if none did. Throws when
    /// the connection is closed or fails.
    public func read(timeout: TimeInterval) throws -> [UInt8] {
        if !pending.isEmpty {
            defer { pending.removeAll() }
            return pending
        }
        return try readRaw(timeout: timeout)
    }

    private func readRaw(timeout: TimeInterval) throws -> [UInt8] {
        let n = waitFor(fd, POLLIN, timeout: timeout)
        if n < 0 {
            if errno == EINTR { return [] }
            throw SocketError.last("receive")
        }
        if n == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: 8192)
        let r = recv(fd, &buf, buf.count, 0)
        if r == 0 { throw SocketError("the server closed the connection") }
        if r < 0 {
            if errno == EAGAIN || errno == EINTR { return [] }
            throw SocketError.last("receive")
        }
        return Array(buf[0..<r])
    }

    /// One `\n`-terminated line, without the terminator.
    public func readLine(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let i = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<i], as: UTF8.self)
                pending.removeSubrange(...i)
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pending.count < 1024 else { throw RemoteError.notRigHelm }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw SocketError("the server did not answer") }
            pending += try readRaw(timeout: left)
        }
    }

    public func write(_ text: String) throws {
        try write(Array(text.utf8))
    }

    public func write(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? SocketError("sending to the server timed out") : SocketError.last("send")
            }
            off += n
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

// MARK: - UDP

public final class UDPSocket {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    public let localPort: UInt16

    /// `reusePort` lets several programs on one machine share a discovery port.
    public init(port: UInt16 = 0, reusePort: Bool = false, broadcast: Bool = false) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        if reusePort {
            setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            setOption(fd, SOL_SOCKET, SO_REUSEPORT, 1)
        }
        if broadcast {
            setOption(fd, SOL_SOCKET, SO_BROADCAST, 1)
        }
        // Room for Wi-Fi delivering audio in clumps.
        setOption(fd, SOL_SOCKET, SO_RCVBUF, 256 * 1024)
        var addr = sockaddr_in(ip: 0, port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            let e = SocketError.last("bind UDP port \(port)")
            Darwin.close(fd)
            throw e
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.fd = fd
        localPort = bound.port
    }

    deinit { close() }

    @discardableResult
    public func send(_ bytes: [UInt8], to ip: UInt32, port: UInt16) -> Bool {
        var addr = sockaddr_in(ip: ip, port: port)
        let n = withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return n == bytes.count
    }

    /// One datagram arriving within `timeout`, with the sender's address.
    public func receive(timeout: TimeInterval) -> (bytes: [UInt8], ip: UInt32, port: UInt16)? {
        guard waitFor(fd, POLLIN, timeout: timeout) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0 else { return nil }
        return (Array(buf[0..<n]), from.ip, from.port)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

// MARK: - Interfaces

public struct NetInterface: Equatable {
    public var name: String
    /// Host-order IPv4 address, netmask and broadcast address.
    public var address: UInt32
    public var netmask: UInt32
    public var broadcast: UInt32
}

/// This device's LAN interfaces: up, IPv4, broadcast-capable (so Wi-Fi and
/// Ethernet, not cellular or VPN tunnels).
public func lanInterfaces() -> [NetInterface] {
    var out: [NetInterface] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return out }
    defer { freeifaddrs(list) }
    var p = list
    while let i = p {
        defer { p = i.pointee.ifa_next }
        let flags = Int32(i.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
              let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
              let m = i.pointee.ifa_netmask
        else { continue }
        let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.ip }
        let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.ip }
        guard addr >> 16 != 0xA9FE else { continue } // link-local 169.254/16
        let iface = NetInterface(name: String(cString: i.pointee.ifa_name), address: addr, netmask: mask, broadcast: addr | ~mask)
        if !out.contains(iface) { out.append(iface) }
    }
    return out
}
