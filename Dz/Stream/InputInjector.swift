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
        let current = CGEvent(source: nil)?.location ?? .zero
        var next = CGPoint(x: current.x + event.dx, y: current.y + event.dy)
        next.x = min(max(next.x, screenBounds.minX), screenBounds.maxX - 1)
        next.y = min(max(next.y, screenBounds.minY), screenBounds.maxY - 1)
        return next
    }

    /// A three finger swipe means a shortcut on macOS. There is no API to post
    /// the gesture itself, so the shortcut that produces the same result is
    /// posted instead. Which shortcut is the user's System Settings, so these
    /// are the defaults rather than the truth.
    private func injectGesture(_ event: InputEvent) {
        // HIG keycodes: left 123, right 124, down 125, up 126.
        var code: CGKeyCode?
        if abs(event.dx) >= abs(event.dy) {
            if event.dx < 0 { code = 124 } else if event.dx > 0 { code = 123 }
        } else {
            if event.dy > 0 { code = 126 } else if event.dy < 0 { code = 125 }
        }
        guard let code else { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        for posted in [down, up] {
            posted.flags = [.maskControl]
            tag(posted)
            posted.post(tap: .cghidEventTap)
        }
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
        let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
        let hasText = !(event.characters ?? "").isEmpty
        if hasText, !shortcut, event.kind != .flagsChanged {
            postUnicode(event.characters!, keyDown: event.kind == .keyDown, event: event)
            return
        }
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(event.code),
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

    /// A pinch becomes the zoom shortcut, because a magnification gesture
    /// cannot be synthesised and this is what it means almost everywhere.
    private func injectMagnify(_ event: InputEvent) {
        guard event.magnification != 0 else { return }
        let increase = event.magnification > 0
        let code: CGKeyCode = increase ? 24 : 27  // "=" and "-"
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        for posted in [down, up] {
            posted.flags = [.maskCommand]
            tag(posted)
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

    private func postUnicode(_ text: String, keyDown: Bool, event: InputEvent) {
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { return }
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
