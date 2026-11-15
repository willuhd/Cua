import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – window/app helpers (same as CLI)
func runningApps() -> [[String:Any]] {
    var out: [[String:Any]] = []
    for a in NSWorkspace.shared.runningApplications {
        if a.activationPolicy == .prohibited { continue }
        out.append(["pid": a.processIdentifier, "name": a.localizedName ?? "?",
                    "bid": a.bundleIdentifier ?? "?", "front": a.isActive])
    }
    return out.sorted { ($0["name"] as! String) < ($1["name"] as! String) }
}
func findPid(app: String?) -> Int32? {
    guard let app = app else { return nil }
    if let n = Int32(app) { return n }
    for a in NSWorkspace.shared.runningApplications {
        if (a.localizedName ?? "").lowercased() == app.lowercased() { return a.processIdentifier }
        if (a.bundleIdentifier ?? "").lowercased() == app.lowercased() { return a.processIdentifier }
        if (a.localizedName ?? "").lowercased().contains(app.lowercased()) { return a.processIdentifier }
    }
    return nil
}
func appNameForPid(_ pid: Int32) -> String {
    for a in NSWorkspace.shared.runningApplications where a.processIdentifier == pid {
        return a.localizedName ?? "?"
    }
    return "?"
}
func windowList(pid: Int32? = nil, onscreenOnly: Bool = true) -> [[String:Any]] {
    let opts: CGWindowListOption = onscreenOnly
        ? [.optionOnScreenOnly, .excludeDesktopElements]
        : [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String:Any]] else { return [] }
    return list.compactMap { w in
        let p = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
        if let pid = pid, Int(pid) != p { return nil }
        return ["wid": w[kCGWindowNumber as String] ?? 0,
                "pid": p,
                "owner": w[kCGWindowOwnerName as String] ?? "?",
                "bounds": w[kCGWindowBounds as String] ?? [:],
                "layer": w[kCGWindowLayer as String] ?? 0,
                "onscreen": w["kCGWindowIsOnScreen"] ?? 0]
    }
}
func defaultWid(pid: Int32) -> UInt32? {
    for onscreen in [true, false] {
        let ws = windowList(pid: pid, onscreenOnly: onscreen)
        let normal = ws.filter { (($0["layer"] as? Int) ?? 0) == 0 }
        if let n = (normal.first ?? ws.first)?["wid"] as? Int { return UInt32(n) }
    }
    return nil
}
func windowBounds(wid: UInt32) -> CGRect? {
    for w in windowList(onscreenOnly: false) {
        if (w["wid"] as? Int) == Int(wid), let b = w["bounds"] as? [String:Any],
           let x = b["X"] as? Double, let y = b["Y"] as? Double,
           let W = b["Width"] as? Double, let H = b["Height"] as? Double {
            return CGRect(x: x, y: y, width: W, height: H)
        }
    }
    return nil
}
func windowOwnerPid(wid: UInt32) -> Int32? {
    for w in windowList(onscreenOnly: false) { if (w["wid"] as? Int) == Int(wid), let p = w["pid"] as? Int { return Int32(p) } }
    return nil
}

