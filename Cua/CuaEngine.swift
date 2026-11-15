import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – Cua engine (tool call bodies; all in-memory)
final class CuaEngine {
    static let shared = CuaEngine()
    func resolvePid(params: [String: Any]) -> Int32? {
        if let p = params["pid"] as? Int { return Int32(p) }
        if let p = params["pid"] as? Double { return Int32(p) }
        if let s = params["app"] as? String { return findPid(app: s) }
        if let s = params["pid"] as? String, let n = Int32(s) { return n }
        return nil
    }
    enum LeaseCheckError: Error { case tool([String: Any]) }
    func requireLease(params: [String: Any]) -> Result<(pid: Int32, session: Session), LeaseCheckError> {
        guard let pid = resolvePid(params: params) else {
            return .failure(.tool(toolResultText("{\"code\":\"NO_TARGET\",\"hint\":\"pass pid or app\"}", isError: true)))
        }
        guard let idStr = params["acquisitionId"] as? String, !idStr.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(.tool(invalidIdResult("missing acquisitionId — call acquire first")))
        }
        switch SessionStore.shared.validate(pid: pid, id: idStr.trimmingCharacters(in: .whitespaces)) {
        case .success(let s): return .success((pid, s))
        case .failure(.held(let s)): return .failure(.tool(leaseHeldResult(s)))
        case .failure(.invalidId(let r)): return .failure(.tool(invalidIdResult(r)))
        case .failure(.unknownApp(let m)): return .failure(.tool(toolResultText("{\"code\":\"UNKNOWN_APP\",\"message\":\"\(m)\"}", isError: true)))
        }
    }
    func toolListApps() -> [String: Any] {
        let apps = runningApps().map { a -> [String: Any] in
            var d: [String: Any] = ["pid": intVal(a["pid"]), "name": a["name"] as! String, "bid": a["bid"] as! String]
            if let h = SessionStore.shared.sessions().first(where: { $0.pid == Int32(intVal(a["pid"])) }) {
                d["held"] = true; d["acquisitionId"] = h.id; d["agent"] = h.agentLabel ?? "unknown"
            } else { d["held"] = false }
            return d
        }
        let sessions = SessionStore.shared.sessions().map { s -> [String: Any] in
            ["pid": s.pid, "app": s.appName, "bid": s.bid, "agent": s.agentLabel ?? "unknown", "acquisitionId": s.id]
        }
        let payload: [String: Any] = ["apps": apps, "sessions": sessions]
        let text = (try? JSONSerialization.data(withJSONObject: payload))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return toolResultText(text, structured: payload)
    }
    func toolWindows(params: [String: Any]) -> [String: Any] {
        let pid = resolvePid(params: params)
        let list = windowList(pid: pid, onscreenOnly: !(params["all"] as? Bool ?? false))
        let slim = list.map { w -> [String: Any] in
            ["wid": intVal(w["wid"]), "pid": intVal(w["pid"]), "owner": w["owner"] as! String,
             "layer": intVal(w["layer"]), "bounds": w["bounds"] as! [String: Any]]
        }
        let payload: [String: Any] = ["windows": slim]
        let text = (try? JSONSerialization.data(withJSONObject: payload))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return toolResultText(text, structured: payload)
    }
    func toolAcquire(params: [String: Any]) -> [String: Any] {
        guard let pid = resolvePid(params: params) else {
            return toolResultText("{\"code\":\"NO_TARGET\",\"hint\":\"pass pid or app\"}", isError: true)
        }
        // Verify app exists
        if appNameForPid(pid) == "?" {
            if defaultWid(pid: pid) == nil {
                return toolResultText("{\"code\":\"NO_SUCH_PID\",\"hint\":\"no running app with that pid\"}", isError: true)
            }
        }
        let label = (params["agentLabel"] as? String) ?? (params["agent"] as? String)
        switch SessionStore.shared.acquire(pid: pid, agentLabel: label) {
        case .success(let s):
            let payload: [String: Any] = ["acquisitionId": s.id, "pid": s.pid, "app": s.appName]
            let text = (try? JSONSerialization.data(withJSONObject: payload))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return toolResultText(text, structured: payload)
        case .failure(.held(let s)):
            return leaseHeldResult(s)
        case .failure(let e):
            return toolResultText("{\"code\":\"ACQUIRE_FAILED\",\"message\":\"\(e)\"}", isError: true)
        }
    }
    func toolRelease(params: [String: Any]) -> [String: Any] {
        guard let pid = resolvePid(params: params),
              let idStr = params["acquisitionId"] as? String, !idStr.trimmingCharacters(in: .whitespaces).isEmpty else {
            return invalidIdResult("missing pid or acquisitionId")
        }
        switch SessionStore.shared.release(pid: pid, id: idStr.trimmingCharacters(in: .whitespaces)) {
        case .success:
            return toolResultText("{\"ok\":true}")
        case .failure(.invalidId(let r)):
            return invalidIdResult(r)
        case .failure(.held(let s)):
            return leaseHeldResult(s)
        case .failure(let e):
            return toolResultText("{\"code\":\"RELEASE_FAILED\",\"message\":\"\(e)\"}", isError: true)
        }
    }
    func toolScreenshot(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else {
            if case .failure(.tool(let r)) = requireLease(params: params) { return r }
            return invalidIdResult("invalid id")
        }
        let widRaw = (params["wid"] as? Int).map { UInt32($0) } ?? ((params["wid"] as? Double).map { UInt32($0) })
        var wid = widRaw
        if wid == nil { wid = defaultWid(pid: t.pid) }
        let grid = (params["grid"] as? Int) ?? ((params["grid"] as? Double).map { Int($0) }) ?? 0
        let clean = params["clean"] as? Bool ?? false
        var cur: (Double, Double)? = nil
        if let s = params["cursor"] as? String {
            if s == "last" || s == "show" { cur = SessionStore.shared.lastCursor() }
            else {
                let p = s.split(separator: ",")
                if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { cur = (x, y) }
            }
        }
        if clean { cur = nil }
        guard let data = captureScreenshotData(wid: wid, grid: clean ? 0 : grid, cursor: cur) else {
            return toolResultText("{\"code\":\"CAPTURE_FAILED\",\"hint\":\"grant Screen Recording to Cua in Settings → Privacy & Security\"}", isError: true)
        }
        let w = wid ?? 0
        let caption = "screenshot wid=\(w) bytes=\(data.count)"
        let structured: [String: Any] = ["wid": Int(w), "pid": t.pid, "bytes": data.count]
        return toolResultImage(png: data, caption: caption, structured: structured)
    }
    func toolMove(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else { return invalidIdResult("invalid id") }
        var wid = ((params["wid"] as? Int).map { UInt32($0) }) ?? (defaultWid(pid: t.pid)) ?? 0
        if wid == 0 { wid = defaultWid(pid: t.pid) ?? 0 }
        var dst: (Double, Double)? = nil
        if let x = params["toX"] as? Double, let y = params["toY"] as? Double { dst = (x, y) }
        else if let x = params["toX"] as? Int, let y = params["toY"] as? Int { dst = (Double(x), Double(y)) }
        else if let s = params["to"] as? String {
            let p = s.split(separator: ","); if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { dst = (x, y) }
        } else if let dx = params["byX"] as? Double, let dy = params["byY"] as? Double {
            if let last = SessionStore.shared.lastCursor() { dst = (last.0 + dx, last.1 + dy) }
            else if let b = windowBounds(wid: wid) { dst = (Double(b.midX) + dx, Double(b.midY) + dy) }
        }
        guard let to = dst else { return toolResultText("{\"code\":\"BAD_ARGS\",\"hint\":\"pass toX/toY or byX/byY\"}", isError: true) }
        SessionStore.shared.saveCursor(pid: t.pid, wid: wid, x: to.0, y: to.1)
        let grid = (params["grid"] as? Int) ?? 100
        if let data = captureScreenshotData(wid: wid == 0 ? nil : wid, grid: grid, cursor: to) {
            let caption = "cursor=\(Int(to.0)),\(Int(to.1)) wid=\(wid)"
            return toolResultImage(png: data, caption: caption, structured: ["cursor": [Int(to.0), Int(to.1)], "wid": Int(wid)])
        } else {
            let payload: [String: Any] = ["ok": true, "cursor": [Int(to.0), Int(to.1)], "shot_error": "capture failed"]
            let text = (try? JSONSerialization.data(withJSONObject: payload))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return toolResultText(text, structured: payload)
        }
    }
    func toolClick(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else { return invalidIdResult("invalid id") }
        var x: Double? = params["x"] as? Double ?? (params["x"] as? Int).map { Double($0) }
        var y: Double? = params["y"] as? Double ?? (params["y"] as? Int).map { Double($0) }
        if x == nil, let s = params["at"] as? String { let p = s.split(separator: ","); if p.count == 2 { x = Double(p[0]); y = Double(p[1]) } }
        guard let cx = x, let cy = y else { return toolResultText("{\"code\":\"BAD_ARGS\",\"hint\":\"pass x,y or at\"}", isError: true) }
        var wid = ((params["wid"] as? Int).map { UInt32($0) }) ?? (defaultWid(pid: t.pid)) ?? 0
        if wid == 0, let w = defaultWid(pid: t.pid) { wid = w }
        let bg = params["bg"] as? Bool ?? true
        let focus = params["focus"] as? Bool ?? false
        let dbl = params["double"] as? Bool ?? false
        let right = params["right"] as? Bool ?? false
        var local = CGPoint(x: cx, y: cy)
        if let b = windowBounds(wid: wid) { local = CGPoint(x: cx - b.origin.x, y: cy - b.origin.y) }
        let group = Int64(Date().timeIntervalSince1970 * 1000) % 100000
        var fo = FocusOutcome()
        if bg {
            fo = driveWithFocus(focus, pid: t.pid, wid: wid) {
                let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
                    right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
                let downs = dbl ? 2 : 1
                for i in 0..<downs {
                    guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: button),
                          let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: button) else { continue }
                    routeMouse(down, wid: wid, pid: t.pid, local: local, clickState: Int64(i+1), group: group)
                    routeMouse(up, wid: wid, pid: t.pid, local: local, clickState: Int64(i+1), group: group)
                    postToPid(down, pid: t.pid); usleep(30_000); postToPid(up, pid: t.pid)
                    if dbl && i == 0 { usleep(80_000) }
                }
            }
        } else {
            let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
                right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: button) else {
                return toolResultText("{\"code\":\"EVENT_FAILED\"}", isError: true)
            }
            down.post(tap: .cghidEventTap); usleep(30_000); up.post(tap: .cghidEventTap)
            if dbl { usleep(80_000); down.post(tap: .cghidEventTap); usleep(30_000); up.post(tap: .cghidEventTap) }
        }
        SessionStore.shared.saveCursor(pid: t.pid, wid: wid, x: cx, y: cy)
        var o: [String: Any] = ["ok": true, "bg": bg, "at": [Int(cx), Int(cy)], "wid": Int(wid), "pid": t.pid]
        o.merge(fo.jsonFields) { _, b in b }
        let text = (try? JSONSerialization.data(withJSONObject: o))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return toolResultText(text, structured: o)
    }
    func toolType(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else { return invalidIdResult("invalid id") }
        guard let text = params["text"] as? String else { return toolResultText("{\"code\":\"BAD_ARGS\",\"hint\":\"pass text\"}", isError: true) }
        let bg = params["bg"] as? Bool ?? true
        let focus = params["focus"] as? Bool ?? false
        var wid = ((params["wid"] as? Int).map { UInt32($0) }) ?? (defaultWid(pid: t.pid)) ?? 0
        if wid == 0, let w = defaultWid(pid: t.pid) { wid = w }
        let fo = driveWithFocus(focus, pid: t.pid, wid: wid) { typeText(text, pid: t.pid, bg: bg) }
        var o: [String: Any] = ["ok": true, "typed": text.count, "bg": bg]
        o.merge(fo.jsonFields) { _, b in b }
        let t2 = (try? JSONSerialization.data(withJSONObject: o))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return toolResultText(t2, structured: o)
    }
    func toolKey(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else { return invalidIdResult("invalid id") }
        var code: UInt16? = nil
        if let c = params["code"] as? Int { code = UInt16(c) }
        else if let c = params["code"] as? Double { code = UInt16(c) }
        guard let cd = code else { return toolResultText("{\"code\":\"BAD_ARGS\",\"hint\":\"pass code\"}", isError: true) }
        let bg = params["bg"] as? Bool ?? true
        let focus = params["focus"] as? Bool ?? false
        let holdMs = (params["holdMs"] as? Int) ?? ((params["holdMs"] as? Double).map { Int($0) }) ?? (bg ? 300 : 50)
        var flags: CGEventFlags = []
        if params["shift"] as? Bool ?? false { flags.insert(.maskShift) }
        if params["ctrl"] as? Bool ?? false { flags.insert(.maskControl) }
        if params["alt"] as? Bool ?? false { flags.insert(.maskAlternate) }
        if params["cmd"] as? Bool ?? false { flags.insert(.maskCommand) }
        if params["fn"] as? Bool ?? false { flags.insert(.maskSecondaryFn) }
        let chr = params["char"] as? String
        var wid = ((params["wid"] as? Int).map { UInt32($0) }) ?? (defaultWid(pid: t.pid)) ?? 0
        if wid == 0, let w = defaultWid(pid: t.pid) { wid = w }
        let fo = driveWithFocus(focus, pid: t.pid, wid: wid) { postKey(cd, pid: t.pid, bg: bg, holdMs: holdMs, flags: flags, char: chr) }
        var o: [String: Any] = ["ok": true, "hold_ms": holdMs, "bg": bg, "code": Int(cd)]
        if !flags.isEmpty {
            var m: [String] = []
            if flags.contains(.maskShift) { m.append("shift") }
            if flags.contains(.maskControl) { m.append("ctrl") }
            if flags.contains(.maskAlternate) { m.append("alt") }
            if flags.contains(.maskCommand) { m.append("cmd") }
            if flags.contains(.maskSecondaryFn) { m.append("fn") }
            o["modifiers"] = m
        }
        if let chr = chr { o["char"] = chr }
        o.merge(fo.jsonFields) { _, b in b }
        let t2 = (try? JSONSerialization.data(withJSONObject: o))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return toolResultText(t2, structured: o)
    }
    func toolScroll(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else { return invalidIdResult("invalid id") }
        var x: Double? = params["x"] as? Double ?? (params["x"] as? Int).map { Double($0) }
        var y: Double? = params["y"] as? Double ?? (params["y"] as? Int).map { Double($0) }
        if x == nil, let s = params["at"] as? String { let p = s.split(separator: ","); if p.count == 2 { x = Double(p[0]); y = Double(p[1]) } }
        guard let cx = x, let cy = y else { return toolResultText("{\"code\":\"BAD_ARGS\",\"hint\":\"pass x,y or at\"}", isError: true) }
        let dx = Int32((params["dx"] as? Int) ?? ((params["dx"] as? Double).map { Int($0) }) ?? 0)
        let dy = Int32((params["dy"] as? Int) ?? ((params["dy"] as? Double).map { Int($0) }) ?? 0)
        let bg = params["bg"] as? Bool ?? true
        let focus = params["focus"] as? Bool ?? false
        var wid = ((params["wid"] as? Int).map { UInt32($0) }) ?? (defaultWid(pid: t.pid)) ?? 0
        if wid == 0, let w = defaultWid(pid: t.pid) { wid = w }
        var local = CGPoint(x: cx, y: cy)
        if let b = windowBounds(wid: wid) { local = CGPoint(x: cx - b.origin.x, y: cy - b.origin.y) }
        let fo = driveWithFocus(focus, pid: t.pid, wid: wid) {
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            e.location = CGPoint(x: cx, y: cy)
            if wid != 0 { routeMouse(e, wid: wid, pid: t.pid, local: local, clickState: 0, group: 0) }
            if bg { postToPid(e, pid: t.pid) } else { e.post(tap: .cghidEventTap) }
        }
        var o: [String: Any] = ["ok": true, "bg": bg]
        o.merge(fo.jsonFields) { _, b in b }
        let t2 = (try? JSONSerialization.data(withJSONObject: o))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return toolResultText(t2, structured: o)
    }
    func toolDrag(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else { return invalidIdResult("invalid id") }
        func pt(_ prefix: String) -> (Double, Double)? {
            if let x = params[prefix + "X"] as? Double, let y = params[prefix + "Y"] as? Double { return (x, y) }
            if let x = params[prefix + "X"] as? Int, let y = params[prefix + "Y"] as? Int { return (Double(x), Double(y)) }
            return nil
        }
        var f = pt("from"), tt = pt("to")
        if f == nil, let s = params["from"] as? String { let p = s.split(separator: ","); if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { f = (x, y) } }
        if tt == nil, let s = params["to"] as? String { let p = s.split(separator: ","); if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { tt = (x, y) } }
        guard let ff = f, let ttt = tt else { return toolResultText("{\"code\":\"BAD_ARGS\",\"hint\":\"pass fromX/fromY + toX/toY\"}", isError: true) }
        let bg = params["bg"] as? Bool ?? true
        let focus = params["focus"] as? Bool ?? false
        var wid = ((params["wid"] as? Int).map { UInt32($0) }) ?? (defaultWid(pid: t.pid)) ?? 0
        if wid == 0, let w = defaultWid(pid: t.pid) { wid = w }
        func mk(_ type: CGEventType, _ p: (Double, Double)) -> CGEvent? {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: p.0, y: p.1), mouseButton: .left) else { return nil }
            var local = CGPoint(x: p.0, y: p.1)
            if let b = windowBounds(wid: wid) { local = CGPoint(x: p.0 - b.origin.x, y: p.1 - b.origin.y) }
            routeMouse(e, wid: wid, pid: t.pid, local: local, clickState: 1, group: 999)
            return e
        }
        let fo = driveWithFocus(focus, pid: t.pid, wid: wid) {
            let steps = 12
            if bg {
                if let d = mk(.leftMouseDown, ff) { postToPid(d, pid: t.pid) }
                for i in 1...steps {
                    let p = (ff.0 + (ttt.0 - ff.0) * Double(i) / Double(steps), ff.1 + (ttt.1 - ff.1) * Double(i) / Double(steps))
                    if let e = mk(.leftMouseDragged, p) { postToPid(e, pid: t.pid) }
                    usleep(15_000)
                }
                if let u = mk(.leftMouseUp, ttt) { postToPid(u, pid: t.pid) }
            } else {
                if let d = mk(.leftMouseDown, ff) { d.post(tap: .cghidEventTap) }
                for i in 1...steps {
                    let p = (ff.0 + (ttt.0 - ff.0) * Double(i) / Double(steps), ff.1 + (ttt.1 - ff.1) * Double(i) / Double(steps))
                    if let e = mk(.leftMouseDragged, p) { e.post(tap: .cghidEventTap) }
                    usleep(15_000)
                }
                if let u = mk(.leftMouseUp, ttt) { u.post(tap: .cghidEventTap) }
            }
        }
        var o: [String: Any] = ["ok": true, "bg": bg]
        o.merge(fo.jsonFields) { _, b in b }
        let t2 = (try? JSONSerialization.data(withJSONObject: o))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return toolResultText(t2, structured: o)
    }
    func toolAx(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else { return invalidIdResult("invalid id") }
        let depth = (params["depth"] as? Int) ?? ((params["depth"] as? Double).map { Int($0) }) ?? 8
        let limit = (params["maxNodes"] as? Int) ?? ((params["maxNodes"] as? Double).map { Int($0) }) ?? 4000
        let text = axDump(pid: t.pid, maxDepth: depth, limit: limit)
        return toolResultText(text)
    }
    func toolPress(params: [String: Any]) -> [String: Any] {
        guard case .success(let t) = requireLease(params: params) else { return invalidIdResult("invalid id") }
        guard let idx = (params["index"] as? Int) ?? ((params["index"] as? Double).map { Int($0) }) else {
            return toolResultText("{\"code\":\"BAD_ARGS\",\"hint\":\"pass index\"}", isError: true)
        }
        let depth = (params["depth"] as? Int) ?? 8
        let limit = (params["maxNodes"] as? Int) ?? 4000
        buildAXIndex(pid: t.pid, maxDepth: depth, limit: limit)
        guard idx >= 0, idx < axIndex.count else {
            return toolResultText("{\"code\":\"BAD_INDEX\",\"size\":\(axIndex.count)}", isError: true)
        }
        let n = axIndex[idx]
        if let wantRole = params["expectRole"] as? String, wantRole != n.role {
            return toolResultText("{\"code\":\"GUARD_ROLE\",\"message\":\"index \(idx) is \(n.role), expected \(wantRole)\"}", isError: true)
        }
        if let wantTitle = params["expectTitle"] as? String, !n.title.localizedCaseInsensitiveContains(wantTitle) {
            return toolResultText("{\"code\":\"GUARD_TITLE\",\"message\":\"title mismatch\"}", isError: true)
        }
        let r = AXUIElementPerformAction(n.ref, "AXPress" as CFString)
        let payload: [String: Any] = ["ok": r == .success, "index": idx, "role": n.role,
                                     "title": String(n.title.prefix(60)), "ax_error": r.rawValue]
        let text = (try? JSONSerialization.data(withJSONObject: payload))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return toolResultText(text, isError: r != .success, structured: payload)
    }
    func dispatch(tool: String, params: [String: Any]) -> [String: Any] {
        switch tool {
        case "list_apps": return toolListApps()
        case "windows": return toolWindows(params: params)
        case "acquire": return toolAcquire(params: params)
        case "release": return toolRelease(params: params)
        case "screenshot": return toolScreenshot(params: params)
        case "move": return toolMove(params: params)
        case "click": return toolClick(params: params)
        case "type": return toolType(params: params)
        case "key": return toolKey(params: params)
        case "scroll": return toolScroll(params: params)
        case "drag": return toolDrag(params: params)
        case "ax": return toolAx(params: params)
        case "press": return toolPress(params: params)
        default: return toolResultText("{\"code\":\"NO_SUCH_TOOL\",\"tool\":\"\(tool)\"}", isError: true)
        }
    }
}

