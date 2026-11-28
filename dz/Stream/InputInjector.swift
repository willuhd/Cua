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
    /// Events posted from a null source are not treated as hardware by the
    /// system hotkey machinery, so Command-Space and the Fn modifier did
    /// nothing on the host. A HID system source is what makes a synthetic
    /// event indistinguishable from the keyboard's own.
    private let source = CGEventSource(stateID: .hidSystemState)
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
            injectScroll(event)
        case .magnify:
            injectMagnify(event)
        case .gesture:
            injectGesture(event)
        case .keyDown, .keyUp, .flagsChanged:
            injectKey(event)
        }
    }

    /// Where a motion event should land.
    ///
    /// In locked mode the client confines its cursor and reports deltas, so the
    /// absolute position it sends is meaningless; the cursor has to be moved by
    /// the delta from where it currently is. Free mode is the opposite.
    private func destination(for event: InputEvent) -> CGPoint {
        guard event.dx != 0 || event.dy != 0 else { return point(event.x, event.y) }
        let current = CGEvent(source: source)?.location ?? .zero
        var next = CGPoint(x: current.x + event.dx, y: current.y + event.dy)
        next.x = min(max(next.x, screenBounds.minX), screenBounds.maxX - 1)
        next.y = min(max(next.y, screenBounds.minY), screenBounds.maxY - 1)
        return next
    }

    /// True for the private use range AppKit uses to describe keys that have
    /// no character: arrows, function keys, and the navigation cluster.
    private func isFunctionKey(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return (0xF700...0xF8FF).contains(scalar.value)
    }

    /// Text goes by character and everything else by keycode.
    ///
    /// The character path is what makes the layout and any input method on the
    /// client behave correctly. It is also exactly wrong for a shortcut: a
    /// command key chord needs the physical key, so anything with a command,
    /// control or option modifier is posted by keycode instead. Getting this
    /// backwards types the letter instead of firing the menu item.
    private func injectKey(_ event: InputEvent) {
        let flags = CGEventFlags(rawValue: event.flags)

        // A modifier transition is a flagsChanged event carrying the new
        // state. Posting it as a key press of the modifier's keycode tells the
        // host nothing, which is why no modifier reached it before, Fn least
        // of all: Fn exists only as a flag bit and has no other expression.
        if event.kind == .flagsChanged {
            postFlagsChanged(event, flags: flags)
            return
        }
        let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
        // Arrow keys, function keys, Home, End, Page Up and Down and Escape
        // all report a character, but it is in the private use range
        // U+F700...U+F8FF rather than text. Sending those down the character
        // path posts a nonsense keycode and the host reacts to the wrong key,
        // which is why arrows were moving the Dock selection instead.
        let text = event.characters ?? ""
        let hasText = !text.isEmpty && !isFunctionKey(text)
        if hasText, !shortcut, event.kind != .flagsChanged {
            postUnicode(text, keyDown: event.kind == .keyDown, event: event)
            return
        }
        guard let cg = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(event.code),
                               keyDown: event.kind != .keyUp) else { return }
        cg.flags = flags
        if event.isRepeat { cg.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        tag(cg)
        cg.post(tap: .cghidEventTap)
    }

    /// A trackpad scroll carries a phase and, after the fingers lift, a
    /// momentum phase that the system continues on its own. Posting without
    /// them gives the host a mouse wheel: no momentum, no rubber banding.
    private func injectScroll(_ event: InputEvent) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(event.dy), wheel2: Int32(event.dx), wheel3: 0) else { return }
        cg.location = point(event.x, event.y)
        cg.flags = CGEventFlags(rawValue: event.flags)
        if event.continuous {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        if event.phase != 0 {
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(event.phase))
        }
        if event.momentumPhase != 0 {
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(event.momentumPhase))
        }
        tag(cg)
        cg.post(tap: .cghidEventTap)
    }

    /// A pinch is posted as a pinch: a zoom gesture with a phase and a value.
    /// The window server turns it into a magnify event for whatever is under
    /// the cursor, which is the same event a real trackpad produces.
    private var openZoomPhase: GestureInjection.Phase = .none

    private func injectMagnify(_ event: InputEvent) {
        let requested = GestureInjection.Phase(rawValue: event.phase) ?? .changed
        if requested == .changed, openZoomPhase == .none {
            postZoom(phase: .began, magnification: event.magnification)
        }
        if requested == .ended, openZoomPhase == .none { return }
        postZoom(phase: requested, magnification: event.magnification)
        if requested == .ended || requested == .cancelled { openZoomPhase = .none }
    }

    private func postZoom(phase: GestureInjection.Phase, magnification: Double) {
        guard let event = GestureInjection.magnify(phase: phase,
                                                   magnification: magnification,
                                                   source: source,
                                                   tag: tag) else { return }
        if phase == .began { openZoomPhase = .began }
        event.post(tap: .cghidEventTap)
    }

    /// A trackpad swipe becomes a navigation swipe, the gesture the system uses
    /// for Spaces and history, rather than the shortcut that imitates it.
    private func injectGesture(_ event: InputEvent) {
        guard let direction = GestureInjection.direction(dx: event.dx, dy: event.dy) else { return }
        for posted in GestureInjection.swipe(direction, source: source, tag: tag) {
            posted.post(tap: .cghidEventTap)
        }
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

    private func postFlagsChanged(_ event: InputEvent, flags: CGEventFlags) {
        guard let cg = CGEvent(source: source) else { return }
        cg.type = .flagsChanged
        cg.setIntegerValueField(.keyboardEventKeycode, value: Int64(event.code))
        cg.flags = flags
        tag(cg)
        cg.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ text: String, keyDown: Bool, event: InputEvent) {
        guard let cg = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return }
        cg.flags = CGEventFlags(rawValue: event.flags)
        if event.isRepeat { cg.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
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
