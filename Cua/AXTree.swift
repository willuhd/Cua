import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – AX (same walk as the original CLI, scoped per lease)
struct AXNode { var idx: Int; var role: String; var title: String; var pos: CGPoint?; var size: CGSize?; var actions: [String]; var ref: AXUIElement }

final class AXIndexStore {
    static let shared = AXIndexStore()
    private let lock = NSLock()
    private var bySession: [String: (nodes: [AXNode], truncated: Bool, timedOut: Bool)] = [:]

    func build(sessionID: String, pid: Int32, wid: UInt32?, maxDepth: Int, limit: Int,
               deadline: Date? = nil) -> Bool {
        var nodes: [AXNode] = []
        var truncated = false
        var timedOut = false
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        let root: AXUIElement
        if let wid = wid, wid != 0 {
            guard let window = axWindowElement(pid: pid, wid: wid) else { return false }
            root = window
        } else {
            root = app
        }
        axWalk(root, depth: 0, maxDepth: max(1, min(maxDepth, 64)), limit: max(1, min(limit, 20_000)),
               deadline: deadline, nodes: &nodes, truncated: &truncated, timedOut: &timedOut)
        lock.lock(); bySession[sessionID] = (nodes, truncated, timedOut); lock.unlock()
        return true
    }

    func nodes(sessionID: String) -> (nodes: [AXNode], truncated: Bool, timedOut: Bool)? {
        lock.lock(); defer { lock.unlock() }
        return bySession[sessionID]
    }

    func remove(sessionID: String) {
        lock.lock(); bySession.removeValue(forKey: sessionID); lock.unlock()
    }
}

private func axWalk(_ el: AXUIElement, depth: Int, maxDepth: Int, limit: Int,
                    deadline: Date?, nodes: inout [AXNode], truncated: inout Bool,
                    timedOut: inout Bool) {
    if timedOut { return }
    if let deadline = deadline, Date() > deadline { timedOut = true; return }
    if depth > maxDepth { return }
    if nodes.count >= limit { truncated = true; return }
    var role: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    var title: AnyObject?
    for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as [CFString] {
        var v: AnyObject?
        if AXUIElementCopyAttributeValue(el, attr, &v) == .success,
           let s = v as? String, !s.isEmpty {
            title = s as AnyObject
            break
        }
    }
    var pos: CGPoint?; var size: CGSize?
    var v: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success,
       let av = v, CFGetTypeID(av) == AXValueGetTypeID() {
        var p = CGPoint.zero
        if AXValueGetValue(av as! AXValue, .cgPoint, &p) { pos = p }
    }
    v = nil
    if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
       let av = v, CFGetTypeID(av) == AXValueGetTypeID() {
        var s = CGSize.zero
        if AXValueGetValue(av as! AXValue, .cgSize, &s) { size = s }
    }
    var acts: [String] = []
    var al: CFArray?
    if AXUIElementCopyActionNames(el, &al) == .success, let a = al as? [String] { acts = a }
    if !acts.isEmpty || pos != nil {
        nodes.append(AXNode(idx: nodes.count, role: (role as? String) ?? "?", title: (title as? String) ?? "",
                            pos: pos, size: size, actions: acts, ref: el))
    }
    var kids: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
       let arr = kids as? [AXUIElement] {
        for k in arr {
            axWalk(k, depth: depth + 1, maxDepth: maxDepth, limit: limit, deadline: deadline,
                   nodes: &nodes, truncated: &truncated, timedOut: &timedOut)
            if timedOut { return }
        }
    } else if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &kids) == .success,
              let arr = kids as? [AXUIElement] {
        for k in arr {
            axWalk(k, depth: depth + 1, maxDepth: maxDepth, limit: limit, deadline: deadline,
                   nodes: &nodes, truncated: &truncated, timedOut: &timedOut)
            if timedOut { return }
        }
    }
}

func axDump(sessionID: String, pid: Int32, wid: UInt32?, maxDepth: Int, limit: Int,
            deadline: Date? = nil) -> (text: String, timedOut: Bool)? {
    guard AXIndexStore.shared.build(sessionID: sessionID, pid: pid, wid: wid, maxDepth: maxDepth,
                                    limit: limit, deadline: deadline) else {
        return nil
    }
    guard let (nodes, truncated, timedOut) = AXIndexStore.shared.nodes(sessionID: sessionID) else {
        return ("", false)
    }
    var lines: [String] = []
    for n in nodes {
        var s = "[\(n.idx)] \(n.role)"
        if !n.title.isEmpty { s += " \"\(n.title.prefix(80))\"" }
        if let p = n.pos { s += String(format: " at %.0f,%.0f", p.x, p.y) }
        if let z = n.size { s += String(format: " size %.0fx%.0f", z.width, z.height) }
        if !n.actions.isEmpty { s += " actions=" + n.actions.joined(separator: ",") }
        lines.append(s)
    }
    if truncated { lines.append("(truncated at \(limit) nodes – raise maxNodes)") }
    return (lines.joined(separator: "\n"), timedOut)
}
