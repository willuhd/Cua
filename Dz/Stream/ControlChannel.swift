//
//  ControlChannel.swift
//  dz
//
//  Input rides a separate reliable stream from video, on purpose.
//
//  Video can lose datagrams: the reassembler drops a torn frame and the next
//  one repairs it. Input cannot. A dropped key release leaves a key stuck down
//  on the host, and a dropped mouse move leaves the pointer somewhere the user
//  did not put it. So input gets its own ordered, length-prefixed channel and
//  leaves the UDP path to the pictures.
//

import Foundation

enum ControlError: Error, CustomStringConvertible {
    case socket(Int32)
    case bind(Int32)
    case connect(Int32)
    case address(String)

    var description: String {
        switch self {
        case .socket(let e): return "control socket failed: \(String(cString: strerror(e)))"
        case .bind(let e): return "control bind failed: \(String(cString: strerror(e)))"
        case .connect(let e): return "control connect failed: \(String(cString: strerror(e)))"
        case .address(let a): return "bad control address: \(a)"
        }
    }
}

final class ControlChannel {
    /// Delivered on the reading queue.
    var onEvent: ((InputEvent) -> Void)?

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "dz.control", qos: .userInteractive)
    private var buffer = Data()
    private let lock = NSLock()

    /// Client side: connects to a host.
    init(host: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd); fd = -1
            throw ControlError.address(host)
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            let e = errno; Darwin.close(fd); fd = -1
            throw ControlError.connect(e)
        }
        // Input is small and latency matters more than throughput.
        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Host side: binds and waits. Kept synchronous and explicit so the caller
    /// controls when a session starts accepting.
    static func listen(port: UInt16) throws -> ControlChannel {
        let channel = try ControlChannel()
        var one: Int32 = 1
        setsockopt(channel.fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(channel.fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { throw ControlError.bind(errno) }
        guard Darwin.listen(channel.fd, 1) == 0 else { throw ControlError.bind(errno) }
        return channel
    }

    private init() {
        fd = socket(AF_INET, SOCK_STREAM, 0)
    }

    /// Accepts one client and starts reading from it. Blocks until someone
    /// connects, so call it off the main thread.
    func acceptAndRead() throws {
        var caddr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let client = withUnsafeMutablePointer(to: &caddr) { accept(fd, $0, &len) }
        guard client >= 0 else { throw ControlError.socket(errno) }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        Darwin.close(fd)
        fd = client
        readLoop()
    }

    /// Starts reading without blocking the caller; used on the client side.
    func startReading() {
        queue.async { [weak self] in self?.readLoop() }
    }

    /// Sends one event. Returns false if the channel is closed.
    @discardableResult
    func send(_ event: InputEvent) -> Bool {
        guard let framed = InputFraming.encode(event) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return false }
        var sent = 0
        let bytes = [UInt8](framed)
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { ptr in
                Darwin.send(fd, ptr.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                for event in InputFraming.drain(&buffer) { onEvent?(event) }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            break
        }
        Darwin.close(fd)
        fd = -1
    }

    func close() {
        lock.lock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
        lock.unlock()
    }

    deinit { close() }
}
