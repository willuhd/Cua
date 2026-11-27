//
//  InputInjector.swift
//  dz
//
//  Host side: turns a received InputEvent into a real event on this Mac.
//
//  Events are tagged so dz's own human-input monitor can tell them apart from
//  the user's, which is what stops the grant from invalidating its own
//  observation every time the agent moves the mouse.
//

import Foundation
import CoreGraphics

final class InputInjector {
    /// Coordinates arrive normalised to the session area, 0...1.
    private var screenBounds: CGRect

    init(screenBounds: CGRect = CGDisplayBounds(CGMainDisplayID())) {
        self.screenBounds = screenBounds
    }

    func updateScreenBounds(_ bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        screenBounds = bounds
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: screenBounds.minX + x * screenBounds.width,
                y: screenBounds.minY + y * screenBounds.height)
    }

    func inject(_ event: InputEvent) {
        switch event.kind {
        case .mouseMove:
            post(type: .mouseMoved, at: destination(for: event), button: .left, event: event)
        case .mouseDrag:
            post(type: .leftMouseDragged, at: destination(for: event), button: .left, event: event)
        case .mouseDown, .mouseUp:
            let button = CGMouseButton(rawValue: UInt32(event.code)) ?? .left
            let down = event.kind == .mouseDown
            let type: CGEventType
            switch button {
            case .right: type = down ? .rightMouseDown : .rightMouseUp
            case .center: type = down ? .otherMouseDown : .otherMouseUp
            default: type = down ? .leftMouseDown : .leftMouseUp
            }
            post(type: type, at: point(event.x, event.y), button: button, event: event)
        case .scroll:
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(event.dy), wheel2: Int32(event.dx), wheel3: 0) else { return }
            cg.location = point(event.x, event.y)
            cg.flags = CGEventFlags(rawValue: event.flags)
            tag(cg)
            cg.post(tap: .cghidEventTap)
        case .keyDown, .keyUp, .flagsChanged:
            // The character path wins when the client sent one: it already
            // reflects the layout and any input method the user is running.
            if let text = event.characters, !text.isEmpty, event.kind != .flagsChanged {
                postUnicode(text, keyDown: event.kind == .keyDown, flags: event.flags)
                return
            }
            guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(event.code),
                                   keyDown: event.kind != .keyUp) else { return }
            cg.flags = CGEventFlags(rawValue: event.flags)
            tag(cg)
            cg.post(tap: .cghidEventTap)
        }
    }

    /// Where a motion event should land.
    ///
    /// In locked mode the client confines its cursor and reports deltas, so the
    /// absolute position it sends is meaningless; the cursor has to be moved by
    /// the delta from where it currently is. Free mode is the opposite.
    private func destination(for event: InputEvent) -> CGPoint {
        guard event.dx != 0 || event.dy != 0 else { return point(event.x, event.y) }
        let current = CGEvent(source: nil)?.location ?? .zero
        var next = CGPoint(x: current.x + event.dx, y: current.y + event.dy)
        next.x = min(max(next.x, screenBounds.minX), screenBounds.maxX - 1)
        next.y = min(max(next.y, screenBounds.minY), screenBounds.maxY - 1)
        return next
    }

    private func post(type: CGEventType, at location: CGPoint, button: CGMouseButton, event: InputEvent) {
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: location, mouseButton: button) else { return }
        cg.flags = CGEventFlags(rawValue: event.flags)
        if event.dx != 0 || event.dy != 0 {
            cg.setIntegerValueField(.mouseEventDeltaX, value: Int64(event.dx))
            cg.setIntegerValueField(.mouseEventDeltaY, value: Int64(event.dy))
        }
        tag(cg)
        cg.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ text: String, keyDown: Bool, flags: UInt64) {
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { return }
        cg.flags = CGEventFlags(rawValue: flags)
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            cg.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        tag(cg)
        cg.post(tap: .cghidEventTap)
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: dzSyntheticEventTag)
    }
}
