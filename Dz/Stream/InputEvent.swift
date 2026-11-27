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
