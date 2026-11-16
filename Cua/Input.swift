import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – event input (same as CLI, focus journaled)
@discardableResult
func postToPid(_ e: CGEvent, pid: Int32) -> Int32 {
    if let fn = Sky.shared.SLEventPostToPid { return fn(pid, e) }
    e.postToPid(pid)
    return 0
}
func routeMouse(_ e: CGEvent, wid: UInt32, pid: Int32, local: CGPoint, clickState: Int64, group: Int64) {
    if let fn = Sky.shared.CGEventSetWindowLocationFn {
        _ = fn(e, local)
    }
    let F = { (v: Int) -> CGEventField in CGEventField(rawValue: UInt32(v))! }
    e.setIntegerValueField(CGEventField(rawValue: 1)!, value: clickState)
    e.setIntegerValueField(CGEventField(rawValue: 2)!, value: 0)
    e.setIntegerValueField(CGEventField(rawValue: 7)!, value: 3)
    e.setIntegerValueField(F(51), value: Int64(wid))
    e.setIntegerValueField(F(58), value: group)
    e.setIntegerValueField(F(91), value: Int64(wid))
    e.setIntegerValueField(F(92), value: Int64(wid))
    e.setIntegerValueField(F(40), value: Int64(pid))
}
func warpCursor(to p: CGPoint) {
    CGWarpMouseCursorPosition(p)
    CGAssociateMouseAndMouseCursorPosition(1)
}
func currentCursorPosition() -> CGPoint? {
    CGEvent(source: nil)?.location
}
func postMouseMoved(pid: Int32, wid: UInt32, local: CGPoint, screen: CGPoint, bg: Bool, group: Int64) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                          mouseCursorPosition: screen, mouseButton: .left) else { return }
    routeMouse(e, wid: wid, pid: pid, local: local, clickState: 0, group: group)
    if bg { postToPid(e, pid: pid) } else { e.post(tap: .cghidEventTap) }
}
func postKey(_ code: UInt16, pid: Int32, bg: Bool, holdMs: Int, flags: CGEventFlags = [], char: String? = nil) {
    if let dn = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) {
        dn.flags = flags
        if let c = char { keyboardSetUnicode(dn, c) }
        if bg { postToPid(dn, pid: pid) } else { dn.post(tap: .cghidEventTap) }
    }
    usleep(UInt32(max(holdMs, 0) * 1000))
    if let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) {
        up.flags = flags
        if let c = char { keyboardSetUnicode(up, c) }
        if bg { postToPid(up, pid: pid) } else { up.post(tap: .cghidEventTap) }
    }
}
func keyboardSetUnicode(_ e: CGEvent, _ s: String) {
    let units = Array(s.utf16)
    guard !units.isEmpty else { return }
    units.withUnsafeBufferPointer { buf in
        e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
    }
}
func utf16Chunks(_ s: String, limit: Int = 16) -> [[UniChar]] {
    var chunks: [[UniChar]] = []
    var cur: [UniChar] = []
    for ch in s {
        let units = Array(String(ch).utf16)
        if !cur.isEmpty && cur.count + units.count > limit { chunks.append(cur); cur = [] }
        cur.append(contentsOf: units)
        if cur.count >= limit { chunks.append(cur); cur = [] }
    }
    if !cur.isEmpty { chunks.append(cur) }
    return chunks
}
func typeText(_ text: String, pid: Int32, bg: Bool) {
    for ch in text {
        if ch == "\n" || ch == "\r" { postKey(36, pid: pid, bg: bg, holdMs: 15); continue }
        if ch == "\t" { postKey(48, pid: pid, bg: bg, holdMs: 15); continue }
        for chunk in utf16Chunks(String(ch)) {
            var u = chunk
            guard let dn = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            dn.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            if bg { postToPid(dn, pid: pid); postToPid(up, pid: pid) }
            else { dn.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
        }
        usleep(4_000)
    }
}

