import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – focus journal (same policy: never steal unless focus=true)
struct FocusSnapshot {
    var frontPSN: ProcessSerialNumber
    var frontPid: Int32
    var frontWid: UInt32?
    var frontName: String
}
struct FocusOutcome {
    var took = false
    var alreadyFront = false
    var focusError: String?
    var restoreError: String?
    var verified: Bool?
    var jsonFields: [String: Any] {
        var d: [String: Any] = ["focus_taken": took, "already_front": alreadyFront]
        if let e = focusError { d["focus_error"] = e }
        if let e = restoreError { d["focus_restore_error"] = e }
        if let v = verified { d["focus_restored"] = v }
        return d
    }
}
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
func keyWindowId(pid: Int32) -> UInt32? {
    guard pid != 0, AXIsProcessTrusted() else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    var fw: AnyObject?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &fw) == .success,
          let w = fw, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
    return axElementWindowId(w as! AXUIElement)
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

func snapshotFocus(readKeyWindow: Bool = true) -> FocusSnapshot {
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
    _ = Sky.shared.SLPSGetFrontProcess?(&psn)
    let app = NSWorkspace.shared.frontmostApplication
    let pid = app?.processIdentifier ?? 0
    return FocusSnapshot(frontPSN: psn, frontPid: pid,
                         frontWid: (readKeyWindow && pid != 0) ? keyWindowId(pid: pid) : nil,
                         frontName: app?.localizedName ?? "?")
}
func focusRecord(wid: UInt32, active: UInt8) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 0xF8)
    b[0x04] = 0xF8
    b[0x08] = 0x0D
    b[0x3C] = UInt8(wid & 0xFF); b[0x3D] = UInt8((wid >> 8) & 0xFF)
    b[0x3E] = UInt8((wid >> 16) & 0xFF); b[0x3F] = UInt8((wid >> 24) & 0xFF)
    b[0x8A] = active
    return b
}
func postFocusRecord(_ psn: ProcessSerialNumber, wid: UInt32, active: UInt8) -> String? {
    guard let post = Sky.shared.SLPSPostEventRecordTo else { return "skylight not loaded" }
    var p = psn
    var err: String? = nil
    focusRecord(wid: wid, active: active).withUnsafeBufferPointer { buf in
        if post(&p, buf.baseAddress!) != 0 { err = "focus record post failed (wid \(wid))" }
    }
    return err
}
func stealFocus(pid: Int32, wid: UInt32, prev: FocusSnapshot) -> String? {
    guard Sky.shared.loaded, Sky.shared.SLPSPostEventRecordTo != nil else { return "skylight not loaded" }
    guard let targetPSN = Sky.shared.psnForWindow(wid) else { return "no PSN for window \(wid)" }
    if let prevWid = prev.frontWid, prevWid != wid {
        _ = postFocusRecord(prev.frontPSN, wid: prevWid, active: 0x02)
    }
    return postFocusRecord(targetPSN, wid: wid, active: 0x01)
}
func restoreFocus(to snap: FocusSnapshot, targetWid: UInt32) -> (String?, Bool?) {
    guard Sky.shared.loaded, Sky.shared.SLPSPostEventRecordTo != nil else { return ("skylight not loaded", nil) }
    guard snap.frontPid != 0 else { return ("no front app to restore", nil) }
    if let tpsn = Sky.shared.psnForWindow(targetWid) {
        _ = postFocusRecord(tpsn, wid: targetWid, active: 0x02)
    }
    let wid = snap.frontWid ?? defaultWid(pid: snap.frontPid) ?? 0
    guard wid != 0 else { return ("front window id unknown", nil) }
    var err = postFocusRecord(snap.frontPSN, wid: wid, active: 0x01)
    var verified: Bool? = nil
    for attempt in 0..<2 {
        usleep(80_000)
        guard let now = keyWindowId(pid: snap.frontPid) else { verified = nil; break }
        if now == wid { verified = true; break }
        if attempt == 0 {
            _ = postFocusRecord(snap.frontPSN, wid: wid, active: 0x01)
        } else {
            verified = false
            err = "focus restore left \(snap.frontName) on wid \(now), expected \(wid)"
        }
    }
    return (err, verified)
}
func driveWithFocus(_ want: Bool, pid: Int32, wid: UInt32, _ body: () -> Void) -> FocusOutcome {
    var o = FocusOutcome()
    let snap = snapshotFocus(readKeyWindow: want)
    o.alreadyFront = (snap.frontPid == pid)
    let alreadyKey = (snap.frontPid == pid) && (wid == 0 || snap.frontWid == nil || snap.frontWid == wid)
    if want, !alreadyKey, wid != 0 {
        if let e = stealFocus(pid: pid, wid: wid, prev: snap) {
            o.focusError = e
            clog("focus steal failed: \(e)")
        } else {
            o.took = true
            clog("focus taken from \(snap.frontName) -> \(wid)")
            usleep(120_000)
        }
    }
    body()
    if o.took {
        usleep(40_000)
        let (err, ok) = restoreFocus(to: snap, targetWid: wid)
        o.restoreError = err
        o.verified = ok
        if let err = err { clog("warning: \(err)") }
    }
    return o
}

