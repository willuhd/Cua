import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin


// MARK: – AX window lookup
func axElementWindowId(_ el: AXUIElement) -> UInt32? {
    if let fn = Sky.shared.AXGetWindowFn {
        var wid: CGWindowID = 0
        if fn(el, &wid) == 0, wid != 0 { return UInt32(wid) }
    }
    var pv: AnyObject?, sv: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
          let pv = pv, let sv = sv,
          CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    for w in windowList(onscreenOnly: false) {
        guard let b = w["bounds"] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let W = b["Width"] as? Double, let H = b["Height"] as? Double,
              abs(x - Double(p.x)) < 2, abs(y - Double(p.y)) < 2,
              abs(W - Double(s.width)) < 2, abs(H - Double(s.height)) < 2,
              let n = w["wid"] as? Int else { continue }
        return UInt32(n)
    }
    return nil
}

func axWindowElement(pid: Int32, wid: UInt32) -> AXUIElement? {
    guard wid != 0, AXIsProcessTrusted() else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.5)
    var windows: AnyObject?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
          let arr = windows as? [AXUIElement] else { return nil }
    for w in arr where axElementWindowId(w) == wid { return w }
    return nil
}
