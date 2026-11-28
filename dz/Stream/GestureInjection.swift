//
//  GestureInjection.swift
//  dz
//
//  Real pinch and swipe events.
//
//  A gesture is not a keystroke. macOS delivers a pinch to an application as a
//  magnify NSEvent, and the window server produces one only from a gesture
//  event. CGEventType does not declare a gesture case, but the window server
//  accepts one anyway: an event whose type is NSEventTypeGesture (29) carrying
//  a HID type, a phase and a value. That encoding is in no SDK header; it is
//  what WebKit's own event sender and LinearMouse's GestureKit use, and it is
//  what makes a pinch arrive as a genuine pinch.
//
//  Field numbers and phase values come from those implementations. They are
//  undocumented and Apple guarantees nothing about them, so everything here is
//  defensive: a gesture that cannot be built is dropped, and an open gesture is
//  always closed.
//

import CoreGraphics

enum GestureInjection {
    /// Undocumented fields the window server reads on a gesture event.
    private enum Field {
        static let hidType = CGEventField(rawValue: 110)!
        static let zoomValue = CGEventField(rawValue: 113)!
        static let swipeValue = CGEventField(rawValue: 115)!
        static let phase = CGEventField(rawValue: 132)!
    }

    /// Undocumented HID event types carried in the hidType field.
    private enum HIDType: Int64 {
        case zoom = 8
        case navigationSwipe = 16
    }

    /// CGSGesturePhase, which shares its numbering with NSEventPhase.
    enum Phase: UInt8 {
        case none = 0
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
        case mayBegin = 128
    }

    struct Swipe: OptionSet {
        let rawValue: Int64
        static let up = Swipe(rawValue: 0x01)
        static let down = Swipe(rawValue: 0x02)
        static let left = Swipe(rawValue: 0x04)
        static let right = Swipe(rawValue: 0x08)
    }

    private static let gestureType = CGEventType(rawValue: 29)!

    private static func make(hidType: HIDType, phase: Phase,
                             source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(source: source) else { return nil }
        event.type = gestureType
        event.flags = []
        event.setIntegerValueField(Field.hidType, value: hidType.rawValue)
        event.setIntegerValueField(Field.phase, value: Int64(phase.rawValue))
        return event
    }

    /// One step of a pinch. The magnification is the delta since the last step,
    /// which is exactly what NSEvent reports, so a caller can pass it through.
    static func magnify(phase: Phase, magnification: Double,
                        source: CGEventSource?, tag: (CGEvent) -> Void) -> CGEvent? {
        guard let event = make(hidType: .zoom, phase: phase, source: source) else { return nil }
        event.setDoubleValueField(Field.zoomValue, value: magnification)
        tag(event)
        return event
    }

    /// A navigation swipe is a pair: began with the direction, then ended.
    /// Posting only one of them leaves the receiving app inside the gesture.
    static func swipe(_ direction: Swipe, source: CGEventSource?,
                      tag: (CGEvent) -> Void) -> [CGEvent] {
        guard let began = make(hidType: .navigationSwipe, phase: .began, source: source),
              let ended = make(hidType: .navigationSwipe, phase: .ended, source: source) else { return [] }
        began.setIntegerValueField(Field.swipeValue, value: direction.rawValue)
        tag(began)
        tag(ended)
        return [began, ended]
    }

    static func direction(dx: Double, dy: Double) -> Swipe? {
        if abs(dx) >= abs(dy) {
            if dx < 0 { return .left } else if dx > 0 { return .right }
        } else {
            if dy > 0 { return .up } else if dy < 0 { return .down }
        }
        return nil
    }
}
