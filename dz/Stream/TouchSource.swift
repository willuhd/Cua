//
//  TouchSource.swift
//  dz
//
//  Raw trackpad contacts, read straight from the private MultitouchSupport
//  framework.
//
//  This exists because synthesised gestures cannot be produced any other way.
//  A pinch is not a scroll and not a shortcut: it is a pair of fingers moving
//  apart, and only the WindowServer's own gesture recogniser can turn that
//  into a magnify event for the app under the cursor. So the client forwards
//  contacts and the host replays them as digitizer events, which makes the
//  host produce a genuine pinch, momentum scroll and three finger swipe
//  instead of us guessing what they meant.
//
//  The framework is private. Everything is resolved with dlopen so a missing
//  symbol degrades to "no touch forwarding" rather than a launch failure.
//

import Foundation

struct TouchContact {
    var id: Int32
    var x: Double          // normalised 0...1, origin bottom left
    var y: Double
    var size: Double       // contact area, already normalised
    var angle: Double
    var major: Double
    var minor: Double
    var state: Int32       // 1 beginning, 2 tracking, 4 linger, 7 ended
}

struct TouchFrame {
    var contacts: [TouchContact]
    /// Contacts that have just lifted, so the host can finish the gesture.
    var ended: Int32
    var timestamp: Double
}

final class TouchSource {
    /// Called on the touch queue for every frame that has contacts.
    var onFrame: ((TouchFrame) -> Void)?
    var onError: ((String) -> Void)?

    private typealias CreateList = @convention(c) () -> CFArray?
    private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, TouchCallback?) -> Int32
    private typealias StartDevice = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias StopDevice = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var started = false
    private let queue = DispatchQueue(label: "dz.touch", qos: .userInteractive)

    static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    init() {
        handle = dlopen(Self.frameworkPath, RTLD_LAZY)
        if handle == nil {
            onError?("MultitouchSupport is unavailable; touch forwarding is off")
        }
    }

    var isAvailable: Bool { handle != nil }

    func start() {
        guard let handle, !started else { return }
        guard let createList = symbol(handle, "MTDeviceCreateList", as: CreateList.self),
              let register = symbol(handle, "MTRegisterContactFrameCallback", as: RegisterCallback.self),
              let startDevice = symbol(handle, "MTDeviceStart", as: StartDevice.self) else {
            onError?("MultitouchSupport is missing the symbols this needs")
            return
        }
        guard let list = createList() else { return }
        let count = CFArrayGetCount(list)
        var opened = 0
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            _ = register(device, touchCallback)
            _ = startDevice(device, 0)
            devices.append(device)
            opened += 1
        }
        started = true
        if opened == 0 { onError?("no multitouch devices found") }
        touchSink = self
    }

    func stop() {
        guard let handle, started else { return }
        if let stopDevice = symbol(handle, "MTDeviceStop", as: StopDevice.self) {
            for device in devices { _ = stopDevice(device, 0) }
        }
        devices.removeAll()
        started = false
    }

    private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    fileprivate func deliver(_ contacts: [TouchContact], ended: Int32, timestamp: Double) {
        guard !contacts.isEmpty || ended != 0 else { return }
        onFrame?(TouchFrame(contacts: contacts, ended: ended, timestamp: timestamp))
    }

    deinit { stop() }
}

/// The contact struct MultitouchSupport hands to a frame callback. The layout
/// is fixed by the framework, not by us.
private struct RawContact {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var identifier: Int32 = 0
    var state: Int32 = 0
    var fingerId: Int32 = 0
    var handId: Int32 = 0
    var normalizedX: Float = 0
    var normalizedY: Float = 0
    var velocityX: Float = 0
    var velocityY: Float = 0
    var size: Float = 0
    var zero1: Int32 = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var absoluteX: Float = 0
    var absoluteY: Float = 0
    var zero2: Int32 = 0
    var density: Float = 0
    var unknown1: Float = 0
    var unknown2: Float = 0
    var unknown3: Float = 0
}

private var touchSink: TouchSource?

private typealias TouchCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

private let touchCallback: TouchCallback = { _, rawContacts, count, timestamp, _ in
    guard let rawContacts, count > 0 else { return }
    let buffer = rawContacts.assumingMemoryBound(to: RawContact.self)
    var contacts: [TouchContact] = []
    contacts.reserveCapacity(Int(count))
    var ended: Int32 = 0
    for index in 0..<Int(count) {
        let raw = buffer[index]
        if raw.state == 7 { ended += 1 }
        contacts.append(TouchContact(id: raw.identifier,
                                     x: Double(raw.normalizedX),
                                     y: Double(raw.normalizedY),
                                     size: Double(raw.size),
                                     angle: Double(raw.angle),
                                     major: Double(raw.majorAxis),
                                     minor: Double(raw.minorAxis),
                                     state: raw.state))
    }
    touchSink?.deliver(contacts, ended: ended, timestamp: timestamp)
}
