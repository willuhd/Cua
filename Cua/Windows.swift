import Cocoa
import CoreGraphics

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
    let q = app.lowercased()
    let apps = NSWorkspace.shared.runningApplications
    // Exact bundle id/name first; substring matching is only a fallback.
    for a in apps {
        if (a.bundleIdentifier ?? "").lowercased() == q { return a.processIdentifier }
        if (a.localizedName ?? "").lowercased() == q { return a.processIdentifier }
    }
    for a in apps {
        if (a.localizedName ?? "").lowercased().contains(q) { return a.processIdentifier }
        if (a.bundleIdentifier ?? "").lowercased().contains(q) { return a.processIdentifier }
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
func windowTitle(wid: UInt32) -> String? {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list where (w[kCGWindowNumber as String] as? Int) == Int(wid) {
        if let name = w[kCGWindowName as String] as? String, !name.isEmpty { return name }
    }
    return nil
}

