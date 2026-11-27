//
//  InputEvent.swift
//  dz
//
//  Input travels on dz's own channel, not inside the video protocol, which is
//  the whole reason Fn and gestures can work at all: nothing here has to fit a
//  game-streaming packet layout that only carries Windows virtual key codes.
//
//  A key event carries both a hardware keycode and, when the client has one,
//  the character that key produced. The character path preserves what the
//  keyboard layout and input method decided; the keycode path preserves
//  shortcuts that care about physical keys.
//

import Foundation
import CoreGraphics

struct InputEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case keyDown, keyUp, flagsChanged
        case mouseMove, mouseDown, mouseUp, mouseDrag
        case scroll
    }

    var kind: Kind
    /// Hardware keycode, or the mouse button number.
    var code: UInt16 = 0
    /// CGEventFlags raw value for modifiers and, notably, the Fn bit.
    var flags: UInt64 = 0
    /// The character this keystroke produced, when there is one.
    var characters: String?
    /// Cursor position in the session's coordinate space.
    var x: Double = 0
    var y: Double = 0
    var dx: Double = 0
    var dy: Double = 0
    /// Monotonic send time, for latency measurement.
    var timestampMicros: UInt64 = 0

    var isKey: Bool { kind == .keyDown || kind == .keyUp || kind == .flagsChanged }
    var isMouse: Bool { !isKey && kind != .scroll }
}

/// How the client hands its pointer to the session.
enum PointerCapture {
    /// Cursor is hidden, confined and reported with deltas: for games and drags.
    case locked
    /// Cursor is visible and the host is told where it is: for normal desktop use.
    case free
}

/// Wraps input events for the wire: a length-prefixed stream, because input has
/// to arrive in order and must not be silently dropped the way video can be.
enum InputFraming {
    static func encode(_ event: InputEvent) -> Data? {
        guard let body = try? JSONEncoder().encode(event) else { return nil }
        var out = Data(capacity: 4 + body.count)
        let length = UInt32(body.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(body)
        return out
    }

    /// Pulls complete messages out of a receive buffer, leaving any partial tail.
    static func drain(_ buffer: inout Data) -> [InputEvent] {
        var events: [InputEvent] = []
        while buffer.count >= 4 {
            let b = [UInt8](buffer.prefix(4))
            let length = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            guard length > 0, length < 1_000_000, buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeFirst(4 + length)
            if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                events.append(event)
            }
        }
        return events
    }
}
