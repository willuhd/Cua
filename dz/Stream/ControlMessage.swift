//
//  ControlMessage.swift
//  dz
//
//  The control channel is bidirectional: the client sends input, the host
//  sends back what it is actually doing.
//
//  The host broadcasting its real encode rate is what keeps it from encoding
//  frames nobody will look at. The client can see what it is being sent and
//  what the host is spending, and the numbers on both ends agree because they
//  come from the same place.
//

import Foundation

/// What the host reports so both ends agree on what the stream is doing.
struct SessionStats: Codable, Equatable {
    var role: String
    /// Frames actually encoded in the last measurement window.
    var fps: Double
    var framesSent: Int
    var packetsSent: Int
    var bytesSent: Int
    /// Frames the capture delivered that the cadence gate threw away.
    var framesSkipped: Int
    /// The ceiling the user pinned, echoed back so the client can show both.
    var targetFps: Int
    var timestampMicros: UInt64
}

enum ControlMessage: Codable {
    case input(InputEvent)
    case stats(SessionStats)
    case clipboard(ClipboardPayload)

    private enum CodingKeys: String, CodingKey { case kind, input, stats, clipboard }
    private enum Kind: String, Codable { case input, stats, clipboard }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .input: self = .input(try container.decode(InputEvent.self, forKey: .input))
        case .stats: self = .stats(try container.decode(SessionStats.self, forKey: .stats))
        case .clipboard: self = .clipboard(try container.decode(ClipboardPayload.self, forKey: .clipboard))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .input(let event):
            try container.encode(Kind.input, forKey: .kind)
            try container.encode(event, forKey: .input)
        case .stats(let stats):
            try container.encode(Kind.stats, forKey: .kind)
            try container.encode(stats, forKey: .stats)
        case .clipboard(let payload):
            try container.encode(Kind.clipboard, forKey: .kind)
            try container.encode(payload, forKey: .clipboard)
        }
    }
}

/// Length-prefixed framing for the control stream.
enum ControlFraming {
    static func encode(_ message: ControlMessage) -> Data? {
        guard let body = try? JSONEncoder().encode(message) else { return nil }
        var out = Data(capacity: 4 + body.count)
        let length = UInt32(body.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(body)
        return out
    }

    /// Pulls complete messages out of the buffer.
    ///
    /// A length that cannot be right means the stream is no longer the stream we
    /// are reading, so it is reported rather than skipped: walking on and
    /// hoping would take an unbounded amount of memory and never recover.
    static func drain(_ buffer: inout Data, corrupted: inout Bool) -> [ControlMessage] {
        var messages: [ControlMessage] = []
        while buffer.count >= 4 {
            let head = [UInt8](buffer.prefix(4))
            let length = Int(UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3]))
            guard length > 0, length < 1_000_000 else {
                corrupted = true
                buffer.removeAll()
                return messages
            }
            guard buffer.count >= 4 + length else { break }
            // Data indices are not zero-based once anything has been removed,
            // so the slice has to be expressed from startIndex.
            let start = buffer.startIndex
            let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
            buffer.removeFirst(4 + length)
            if let message = try? JSONDecoder().decode(ControlMessage.self, from: body) {
                messages.append(message)
            }
        }
        return messages
    }
}
