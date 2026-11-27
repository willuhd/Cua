//
//  ControlChannel.swift
//  dz
//
//  Input rides a separate reliable stream from video, on purpose.
//
//  Video can lose datagrams: the reassembler drops a torn frame and the next
//  one repairs it. Input cannot. A dropped key release leaves a key stuck down
//  on the host, and a dropped mouse move leaves the pointer somewhere the user
//  did not put it. So input gets its own ordered, length-prefixed channel.
//
//  Reading and writing run on separate queues. Sending never blocks the caller,
//  because the caller is AppKit delivering a key press: blocking there on a
//  stalled TCP window would freeze the window with a modifier still held down.
//

import Foundation

enum ControlError: Error, CustomStringConvertible {
    case socket(Int32)
    case bind(Int32)
    case connect(Int32)
    case address(String)

    var description: String {
        switch self {
        case .socket(let e): return "control socket failed: " + String(cString: strerror(e))
        case .bind(let e): return "control bind failed: " + String(cString: strerror(e))
        case .connect(let e): return "control connect failed: " + String(cString: strerror(e))
        case .address(let a): return "bad control address: " + a
        }
    }
}

final class ControlChannel {
    /// Everything arriving on the channel, delivered on the read queue.
    var onMessage: ((ControlMessage) -> Void)?
    /// Host side: called once a client connects, with the address its video
    /// should be sent to. The host learns the peer rather than being told.
    var onConnected: ((String) -> Void)?

    private var fd: Int32 = -1
    private let lock = NSLock()
    private let readQueue = DispatchQueue(label: "dz.control.read", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "dz.control.write", qos: .userInteractive)
    private var buffer = Data()

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
        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        boundWrite()
    }

    /// Host side: binds and waits.
    static func listen(port: UInt16) throws -> ControlChannel {
        let channel = try ControlChannel()
        var one: Int32 = 1
        setsockopt(channel.fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
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

    /// A stalled peer must not hold the write queue forever.
    private func boundWrite() {
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Accepts one client then reads from it. Blocks, so call it off the main
    /// thread.
    func acceptAndRead() throws {
        var caddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &caddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
        }
        guard client >= 0 else { throw ControlError.socket(errno) }

        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &caddr.sin_addr, &host, socklen_t(INET_ADDRSTRLEN)) != nil {
            onConnected?(String(cString: host))
        }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        lock.lock()
        Darwin.close(fd)
        fd = client
        boundWrite()
        lock.unlock()
        readLoop()
    }

    @discardableResult
    func send(_ event: InputEvent) -> Bool { enqueue(.input(event)) }
    @discardableResult
    func send(stats: SessionStats) -> Bool { enqueue(.stats(stats)) }

    private func enqueue(_ message: ControlMessage) -> Bool {
        guard let framed = ControlFraming.encode(message) else { return false }
        writeQueue.async { [weak self] in self?.write(framed) }
        return true
    }

    private func write(_ framed: Data) {
        let bytes = [UInt8](framed)
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { ptr in
                Darwin.send(fd, ptr.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            return
        }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            lock.lock()
            let current = fd
            lock.unlock()
            guard current >= 0 else { break }

            let n = recv(current, &chunk, chunk.count, 0)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                for message in ControlFraming.drain(&buffer) { onMessage?(message) }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            break
        }
        close()
    }

    func close() {
        lock.lock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
        lock.unlock()
    }

    deinit { close() }
}
