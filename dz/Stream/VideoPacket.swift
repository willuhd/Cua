//
//  VideoPacket.swift
//  dz
//
//  The video wire format.
//
//  An encoded frame is cut into datagrams carrying a frame index, a fragment
//  index, the number of data fragments, and the total frame size. The last one
//  exists so parity blocks can be trimmed back to exact length on recovery.
//
//  Parity packets carry the same frame index with a fragment index at or past
//  the data count, so a receiver can tell which is which without any extra
//  negotiation.
//
//  Input does not travel here. dz owns the pointer and the keyboard itself.
//

import Foundation

/// One datagram. Fixed 24-byte header, then payload.
struct VideoPacket: Equatable {
    static let magic: UInt16 = 0x647A  // "dz"
    static let version: UInt8 = 1
    static let headerSize = 24

    /// Sized for a 1280-byte tunnel MTU, which is what Tailscale hands out, so
    /// nothing depends on IP fragmentation.
    static let defaultMTU = 1200

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let keyframe = Flags(rawValue: 1 << 0)
        static let parity = Flags(rawValue: 1 << 1)
    }

    var frameIndex: UInt32
    var fragmentIndex: UInt16
    /// Number of data fragments; parity fragments sit above this.
    var fragmentCount: UInt16
    var flags: Flags
    var timestampMicros: UInt64
    /// Bytes in the whole encoded frame, before fragmentation.
    var totalBytes: UInt32
    var payload: Data

    var isKeyframe: Bool { flags.contains(.keyframe) }
    var isParity: Bool { flags.contains(.parity) }

    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(UInt8(truncatingIfNeeded: Self.magic >> 8))
        out.append(UInt8(truncatingIfNeeded: Self.magic))
        out.append(Self.version)
        out.append(flags.rawValue)
        for shift in [24, 16, 8, 0] { out.append(UInt8(truncatingIfNeeded: frameIndex >> UInt32(shift))) }
        out.append(UInt8(truncatingIfNeeded: fragmentIndex >> 8))
        out.append(UInt8(truncatingIfNeeded: fragmentIndex))
        out.append(UInt8(truncatingIfNeeded: fragmentCount >> 8))
        out.append(UInt8(truncatingIfNeeded: fragmentCount))
        for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
            out.append(UInt8(truncatingIfNeeded: timestampMicros >> UInt64(shift)))
        }
        for shift in [24, 16, 8, 0] { out.append(UInt8(truncatingIfNeeded: totalBytes >> UInt32(shift))) }
        out.append(payload)
        return out
    }

    static func decode(_ datagram: Data) -> VideoPacket? {
        guard datagram.count >= headerSize else { return nil }
        let b = [UInt8](datagram)
        guard UInt16(b[0]) << 8 | UInt16(b[1]) == magic, b[2] == version else { return nil }
        let flags = Flags(rawValue: b[3])
        let frameIndex = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        let fragmentIndex = UInt16(b[8]) << 8 | UInt16(b[9])
        let fragmentCount = UInt16(b[10]) << 8 | UInt16(b[11])
        var timestamp: UInt64 = 0
        for i in 12..<20 { timestamp = timestamp << 8 | UInt64(b[i]) }
        let totalBytes = UInt32(b[20]) << 24 | UInt32(b[21]) << 16 | UInt32(b[22]) << 8 | UInt32(b[23])
        guard fragmentCount > 0 else { return nil }
        // Data fragments must sit inside the data count; parity sits above it.
        if !flags.contains(.parity), fragmentIndex >= fragmentCount { return nil }
        let payload = Data(b[headerSize...])
        return VideoPacket(frameIndex: frameIndex, fragmentIndex: fragmentIndex,
                           fragmentCount: fragmentCount, flags: flags,
                           timestampMicros: timestamp, totalBytes: totalBytes, payload: payload)
    }
}

/// Cuts a frame into datagrams, with optional parity.
enum VideoFragmenter {
    /// Fragment sizes are padded to a constant so every data block is directly
    /// usable as a Reed-Solomon block, and the frame length in the header tells
    /// the receiver where the real data stops.
    static func fragments(for frame: Data, frameIndex: UInt32, timestampMicros: UInt64,
                          keyframe: Bool, mtu: Int = VideoPacket.defaultMTU,
                          parityOverhead: Double = 0) -> [VideoPacket] {
        let room = max(1, mtu - VideoPacket.headerSize)
        let count = max(1, (frame.count + room - 1) / room)
        guard count <= Int(UInt16.max) else { return [] }

        var flags: VideoPacket.Flags = []
        if keyframe { flags.insert(.keyframe) }

        var data: [Data] = []
        data.reserveCapacity(count)
        for index in 0..<count {
            let start = frame.startIndex + index * room
            let end = min(start + room, frame.endIndex)
            var block = frame.subdata(in: start..<end)
            if block.count < room { block.append(Data(repeating: 0, count: room - block.count)) }
            data.append(block)
        }

        var out: [VideoPacket] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            out.append(VideoPacket(frameIndex: frameIndex, fragmentIndex: UInt16(index),
                                   fragmentCount: UInt16(count), flags: flags,
                                   timestampMicros: timestampMicros,
                                   totalBytes: UInt32(frame.count), payload: data[index]))
        }

        let parity = FEC.parityCount(for: count, overhead: parityOverhead)
        guard parity > 0 else { return out }
        let blocks = FEC.encode(data: data, parity: parity)
        for (offset, block) in blocks.enumerated() {
            out.append(VideoPacket(frameIndex: frameIndex,
                                   fragmentIndex: UInt16(count + offset),
                                   fragmentCount: UInt16(count),
                                   flags: flags.union(.parity),
                                   timestampMicros: timestampMicros,
                                   totalBytes: UInt32(frame.count), payload: block))
        }
        return out
    }
}

/// Rebuilds frames from datagrams that arrive out of order, twice, or not at
/// all. A frame that cannot be completed is dropped rather than shown torn.
final class FrameAssembler {
    private let maxAgeNanos: UInt64
    private struct Entry {
        var data: [UInt16: VideoPacket]
        var parity: [Int: Data]
        var count: UInt16
        var totalBytes: UInt32
        var first: UInt64
    }
    private var pending: [UInt32: Entry] = [:]
    private var recentlyCompleted: [UInt32] = []

    private(set) var received = 0
    private(set) var duplicates = 0
    private(set) var dropped = 0
    private(set) var stale = 0
    private(set) var recovered = 0

    init(maxAgeSeconds: Double = 1.0) {
        maxAgeNanos = UInt64(maxAgeSeconds * 1_000_000_000)
    }

    func ingest(_ packet: VideoPacket, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Data? {
        received += 1
        if recentlyCompleted.contains(packet.frameIndex) { stale += 1; return nil }

        var entry = pending[packet.frameIndex] ?? Entry(data: [:], parity: [:],
                                                        count: packet.fragmentCount,
                                                        totalBytes: packet.totalBytes, first: now)

        if packet.isParity {
            entry.parity[Int(packet.fragmentIndex) - Int(entry.count)] = packet.payload
        } else {
            if entry.data[packet.fragmentIndex] != nil { duplicates += 1; return nil }
            entry.data[packet.fragmentIndex] = packet
        }
        pending[packet.frameIndex] = entry

        if entry.data.count == Int(entry.count) {
            return complete(packet.frameIndex, entry, neededRecovery: false)
        }

        // Not all here, but parity may be enough to fill the gaps.
        let missing = Int(entry.count) - entry.data.count
        guard missing > 0, entry.parity.count >= missing else { return nil }
        return recover(packet.frameIndex, entry, missing: missing)
    }

    private func complete(_ index: UInt32, _ entry: Entry, neededRecovery: Bool) -> Data? {
        pending.removeValue(forKey: index)
        var frame = Data()
        for i in 0..<entry.count {
            guard let part = entry.data[i] else { dropped += 1; return nil }
            frame.append(part.payload)
        }
        if neededRecovery { recovered += 1 }
        if frame.count > Int(entry.totalBytes) { frame.removeSubrange(Int(entry.totalBytes)..<frame.count) }
        mark(index)
        return frame
    }

    private func recover(_ index: UInt32, _ entry: Entry, missing: Int) -> Data? {
        var known: [Int: Data] = [:]
        for (position, packet) in entry.data { known[Int(position)] = packet.payload }
        var parity: [Data] = []
        for i in 0..<entry.parity.count { parity.append(entry.parity[i] ?? Data()) }
        guard let blocks = try? FEC.decode(received: known, dataCount: Int(entry.count), parity: parity) else {
            return nil
        }
        pending.removeValue(forKey: index)
        var frame = Data()
        for block in blocks { frame.append(contentsOf: block) }
        if frame.count > Int(entry.totalBytes) { frame.removeSubrange(Int(entry.totalBytes)..<frame.count) }
        recovered += 1
        mark(index)
        return frame
    }

    private func mark(_ index: UInt32) {
        recentlyCompleted.append(index)
        if recentlyCompleted.count > 64 { recentlyCompleted.removeFirst() }
    }

    @discardableResult
    func expireStale(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [UInt32] {
        var expired: [UInt32] = []
        for (index, entry) in pending where now &- entry.first > maxAgeNanos {
            pending.removeValue(forKey: index)
            expired.append(index)
            dropped += 1
        }
        return expired.sorted()
    }

    var pendingFrames: Int { pending.count }
}
