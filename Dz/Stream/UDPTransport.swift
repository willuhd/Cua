//
//  UDPTransport.swift
//  dz
//
//  Sends and receives VideoPackets over plain UDP.
//
//  Nothing is adapted here. Loss is expected and handled by reassembly and, in
//  time, parity; the transport itself does not retransmit and does not pace.
//  A retransmit would cost a round trip we do not have on a 300 ms link.
//

import Foundation

enum TransportError: Error, CustomStringConvertible {
    case socket(Int32)
    case bind(Int32)
    case address(String)

    var description: String {
        switch self {
        case .socket(let e): return "socket failed: \(String(cString: strerror(e)))"
        case .bind(let e): return "bind failed: \(String(cString: strerror(e)))"
        case .address(let a): return "bad address: \(a)"
        }
    }
}

/// One-way video sender. Fire and forget: a datagram that is lost is lost.
final class VideoSender {
    private var fd: Int32 = -1
    private var to = sockaddr_in()

    init(host: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TransportError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // A larger send buffer keeps a keyframe from being carved up by the
        // scheduler; the receiver reorders anyway, but fewer drops is cheaper.
        var buffer: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))

        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &to.sin_addr) == 1 else {
            close(fd); fd = -1
            throw TransportError.address(host)
        }
    }

    func send(_ packet: VideoPacket) {
        guard fd >= 0 else { return }
        let datagram = packet.encoded()
        datagram.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var addr = to
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, base, datagram.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func send(_ packets: [VideoPacket]) { for packet in packets { send(packet) } }

    deinit { if fd >= 0 { close(fd) } }
}

/// One-way video receiver.
final class VideoReceiver {
    private var fd: Int32 = -1

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TransportError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var buffer: Int32 = 8 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            let e = errno; close(fd); fd = -1
            throw TransportError.bind(e)
        }
    }

    /// Blocks until a datagram arrives or the timeout expires. Returns nil on
    /// timeout, and on any datagram that is not a well-formed dz packet.
    func receive(timeout: TimeInterval) -> VideoPacket? {
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return nil }
        return VideoPacket.decode(Data(buffer[0..<n]))
    }

    deinit { if fd >= 0 { close(fd) } }
}
