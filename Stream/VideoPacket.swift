//
//  VideoPacket.swift
//  dz
//
//  The video wire format. Modelled on what Moonlight and Sunshine actually do
//  on the wire: an encoded frame is cut into datagrams carrying a frame index,
//  a fragment index and a fragment count, so the receiver can put a frame back
//  together out of order and tell a partial frame from a lost one.
//
//  Input does not travel here. dz owns the pointer and the keyboard itself, so
//  there are no GameStream input packets in this protocol at all.
//

import Foundation

/// One datagram. Fixed 20-byte header, then payload.
struct VideoPacket: Equatable {
    static let magic: UInt16 = 0x647A  // "dz"
    static let version: UInt8 = 1
    static let headerSize = 20

    /// Packets default to a size that survives a 1280-byte tunnel MTU, which is
    /// what Tailscale hands out, without relying on IP fragmentation.
    static let defaultMTU = 1200

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let keyframe = Flags(rawValue: 1 << 0)
        /// Placeholder for parity packets, so the format does not need a
        /// version bump when FEC lands.
        static let parity = Flags(rawValue: 1 << 1)
    }

    var frameIndex: UInt32
    var fragmentIndex: UInt16
    var fragmentCount: UInt16
    var flags: Flags
    var timestampMicros: UInt64
    var payload: Data

    var isKeyframe: Bool { flags.contains(.keyframe) }
    var isLastFragment: Bool { fragmentIndex == fragmentCount - 1 }

    /// Serialises to a datagram.
    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(UInt8(truncatingIfNeeded: Self.magic >> 8))
        out.append(UInt8(truncatingIfNeeded: Self.magic))
        out.append(Self.version)
        out.append(flags.rawValue)
        for shift in [24, 16, 8, 0] {
            out.append(UInt8(truncatingIfNeeded: frameIndex >> UInt32(shift)))
        }
        out.append(UInt8(truncatingIfNeeded: fragmentIndex >> 8))
        out.append(UInt8(truncatingIfNeeded: fragmentIndex))
        out.append(UInt8(truncatingIfNeeded: fragmentCount >> 8))
        out.append(UInt8(truncatingIfNeeded: fragmentCount))
        for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
            out.append(UInt8(truncatingIfNeeded: timestampMicros >> UInt64(shift)))
        }
        out.append(payload)
        return out
    }

    /// Parses a datagram, or nil if it is not ours or is malformed.
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
        guard fragmentCount > 0, fragmentIndex < fragmentCount else { return nil }
        let payload = Data(b[headerSize...])
        return VideoPacket(frameIndex: frameIndex, fragmentIndex: fragmentIndex,
                           fragmentCount: fragmentCount, flags: flags,
                           timestampMicros: timestamp, payload: payload)
    }
}

/// Cuts a frame into datagrams.
enum VideoFragmenter {
    static func fragments(for frame: Data, frameIndex: UInt32, timestampMicros: UInt64,
                          keyframe: Bool, mtu: Int = VideoPacket.defaultMTU) -> [VideoPacket] {
        let room = max(1, mtu - VideoPacket.headerSize)
        let count = max(1, (frame.count + room - 1) / room)
        guard count <= Int(UInt16.max) else { return [] }

        var out: [VideoPacket] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let start = frame.startIndex + index * room
            let end = min(start + room, frame.endIndex)
            var flags: VideoPacket.Flags = []
            if keyframe { flags.insert(.keyframe) }
            out.append(VideoPacket(frameIndex: frameIndex,
                                   fragmentIndex: UInt16(index),
                                   fragmentCount: UInt16(count),
                                   flags: flags,
                                   timestampMicros: timestampMicros,
                                   payload: frame.subdata(in: start..<end)))
        }
        return out
    }
}

/// Rebuilds frames from datagrams that arrive out of order, twice, or not at
/// all. A frame with a missing fragment is dropped rather than shown torn.
final class FrameAssembler {
    /// Frames older than this are considered lost and thrown away.
    private let maxAgeNanos: UInt64
    private var pending: [UInt32: (parts: [UInt16: VideoPacket], count: UInt16, keyframe: Bool, first: UInt64)] = [:]

    private(set) var received = 0
    private(set) var duplicates = 0
    private(set) var dropped = 0
    private(set) var stale = 0
    /// A frame can complete while datagrams for it are still in flight, so we
    /// remember what we have already shown rather than opening a new partial
    /// entry for the stragglers.
    private var recentlyCompleted: [UInt32] = []

    init(maxAgeSeconds: Double = 1.0) {
        maxAgeNanos = UInt64(maxAgeSeconds * 1_000_000_000)
    }

    /// Feeds one datagram. Returns a whole frame when this packet completed one.
    func ingest(_ packet: VideoPacket, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Data? {
        received += 1
        if recentlyCompleted.contains(packet.frameIndex) {
            stale += 1
            return nil
        }
        var entry = pending[packet.frameIndex]
            ?? (parts: [:], count: packet.fragmentCount, keyframe: packet.isKeyframe, first: now)

        if entry.parts[packet.fragmentIndex] != nil {
            duplicates += 1
            return nil
        }
        entry.parts[packet.fragmentIndex] = packet
        pending[packet.frameIndex] = entry

        guard entry.parts.count == Int(entry.count) else { return nil }

        pending.removeValue(forKey: packet.frameIndex)
        var frame = Data()
        for index in 0..<entry.count {
            guard let part = entry.parts[index] else {
                dropped += 1
                return nil
            }
            frame.append(part.payload)
        }
        recentlyCompleted.append(packet.frameIndex)
        if recentlyCompleted.count > 32 { recentlyCompleted.removeFirst() }
        return frame
    }

    /// Gives up on frames that will never complete. Call on a timer; without it
    /// a lost frame leaks until the same index is reused.
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

