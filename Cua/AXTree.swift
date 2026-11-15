import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – AX (same walk, index identical to CLI so --index means same)
struct AXNode { var idx: Int; var role: String; var title: String; var pos: CGPoint?; var size: CGSize?; var actions: [String]; var ref: AXUIElement }
var axIndex: [AXNode] = []
var axLimit = 4000
var axTruncated = false
func axWalk(_ el: AXUIElement, depth: Int, maxDepth: Int) {
    if depth > maxDepth { return }
    if axIndex.count >= axLimit { axTruncated = true; return }
    var role: AnyObject?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    var title: AnyObject?
    for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as [CFString] {
        var v: AnyObject?; if AXUIElementCopyAttributeValue(el, attr, &v) == .success, let s = v as? String, !s.isEmpty { title = s as AnyObject; break }
    }
    var pos: CGPoint?; var size: CGSize?
    var v: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success, CFGetTypeID(v!) == AXValueGetTypeID() {
        var p = CGPoint.zero; if AXValueGetValue(v as! AXValue, .cgPoint, &p) { pos = p }
    }
    v = nil
    if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success, let av = v, CFGetTypeID(av) == AXValueGetTypeID() {
        var s = CGSize.zero; if AXValueGetValue(av as! AXValue, .cgSize, &s) { size = s }
    }
    var acts: [String] = []
    var al: CFArray?; if AXUIElementCopyActionNames(el, &al) == .success, let a = al as? [String] { acts = a }
    if !acts.isEmpty || pos != nil {
        axIndex.append(AXNode(idx: axIndex.count, role: (role as? String) ?? "?", title: (title as? String) ?? "",
                              pos: pos, size: size, actions: acts, ref: el))
    }
    var kids: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
        for k in arr { axWalk(k, depth: depth+1, maxDepth: maxDepth) }
    } else if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
        for k in arr { axWalk(k, depth: depth+1, maxDepth: maxDepth) }
    }
}
func buildAXIndex(pid: Int32, maxDepth: Int, limit: Int) {
    axIndex = []
    axLimit = limit
    axTruncated = false
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2.0)
    axWalk(app, depth: 0, maxDepth: maxDepth)
}
func axDump(pid: Int32, maxDepth: Int, limit: Int) -> String {
    buildAXIndex(pid: pid, maxDepth: maxDepth, limit: limit)
    var lines: [String] = []
    for n in axIndex {
        var s = "[\(n.idx)] \(n.role)"
        if !n.title.isEmpty { s += " \"\(n.title.prefix(80))\"" }
        if let p = n.pos { s += String(format: " at %.0f,%.0f", p.x, p.y) }
        if let z = n.size { s += String(format: " size %.0fx%.0f", z.width, z.height) }
        if !n.actions.isEmpty { s += " actions=" + n.actions.joined(separator: ",") }
        lines.append(s)
    }
    if axTruncated { lines.append("(truncated at \(limit) nodes – raise --max-nodes)") }
    return lines.joined(separator: "\n")
}

