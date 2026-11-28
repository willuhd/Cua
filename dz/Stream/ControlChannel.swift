//
//  ControlChannel.swift
//  dz
//
//  Input rides a separate reliable stream from video, on purpose.
//
//  Video can lose datagrams: the reassembler drops a torn frame and the next
//  one repairs it. Input cannot. A dropped key release leaves a key stuck down
//  on the host, so input gets its own ordered, length-prefixed channel.
//
//  The listening socket and the connected socket are held separately. Closing
//  the listener when a client connects, as this used to, means a host can
//  accept exactly one client per launch and then has to be restarted.
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
    var onMessage: ((ControlMessage) -> Void)?
    /// Host side: called with the address a freshly connected client should
    /// receive video at.
    var onConnected: ((String) -> Void)?

    private var listenFd: Int32 = -1
    private var connFd: Int32 = -1
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "dz.control.write", qos: .userInteractive)
    private var buffer = Data()

    init(host: String, port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard let resolved = NetworkAddress.ipv4(host) else {
            Darwin.close(fd)
            throw ControlError.address(host)
        }
        guard inet_pton(AF_INET, resolved, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw ControlError.address(host)
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            let e = errno; Darwin.close(fd)
            throw ControlError.connect(e)
        }
        connFd = fd
        setNoDelay(fd)
    }

    private init() {}

    /// Host side: binds and listens. The listener stays open for the life of
    /// the session so a client can drop and reconnect.
    static func listen(port: UInt16) throws -> ControlChannel {
        let channel = ControlChannel()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { Darwin.close(fd); throw ControlError.bind(errno) }
        guard Darwin.listen(fd, 4) == 0 else { Darwin.close(fd); throw ControlError.bind(errno) }
        channel.listenFd = fd
        return channel
    }

    private func setNoDelay(_ fd: Int32) {
        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Accepts the next client and reads from it until it goes away. Blocks, so
    /// call it from a worker queue; returns so the caller can accept again.
    func acceptAndRead() throws {
        lock.lock()
        let listener = listenFd
        lock.unlock()
        guard listener >= 0 else { throw ControlError.socket(EBADF) }

        var caddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &caddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &len) }
        }
        guard client >= 0 else { throw ControlError.socket(errno) }

        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &caddr.sin_addr, &host, socklen_t(INET_ADDRSTRLEN)) != nil {
            onConnected?(String(cString: host))
        }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setNoDelay(client)

        lock.lock()
        connFd = client
        buffer.removeAll()
        lock.unlock()

        readLoop(client)

        lock.lock()
        if connFd == client { connFd = -1 }
        lock.unlock()
        Darwin.close(client)
    }

    /// Client side: reads in the background.
    func startReading() {
        DispatchQueue(label: "dz.control.read", qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let fd = self.connFd
            guard fd >= 0 else { return }
            self.readLoop(fd)
        }
    }

    @discardableResult
    func send(_ event: InputEvent) -> Bool { enqueue(.input(event)) }
    @discardableResult
    func send(stats: SessionStats) -> Bool { enqueue(.stats(stats)) }
    @discardableResult
    func send(clipboard: ClipboardPayload) -> Bool { enqueue(.clipboard(clipboard)) }
    @discardableResult
    func send(configure: StreamSettings) -> Bool { enqueue(.configure(configure)) }
    @discardableResult
    func send(hostState: HostSessionState) -> Bool { enqueue(.hostState(hostState)) }

    private func enqueue(_ message: ControlMessage) -> Bool {
        guard let framed = ControlFraming.encode(message) else { return false }
        writeQueue.async { [weak self] in self?.write(framed) }
        return true
    }

    private func write(_ framed: Data) {
        let bytes = [UInt8](framed)
        lock.lock()
        defer { lock.unlock() }
        guard connFd >= 0 else { return }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { ptr in
                Darwin.send(connFd, ptr.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            return
        }
    }

    private func readLoop(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                lock.lock()
                buffer.append(contentsOf: chunk[0..<n])
                var corrupted = false
                let messages = ControlFraming.drain(&buffer, corrupted: &corrupted)
                lock.unlock()
                for message in messages { onMessage?(message) }
                if corrupted {
                    NSLog("dz: control stream is corrupt; dropping the client")
                    return
                }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            return
        }
    }

    func close() {
        lock.lock()
        if connFd >= 0 { shutdown(connFd, SHUT_RDWR); Darwin.close(connFd); connFd = -1 }
        if listenFd >= 0 { shutdown(listenFd, SHUT_RDWR); Darwin.close(listenFd); listenFd = -1 }
        lock.unlock()
    }

    deinit { close() }
}
