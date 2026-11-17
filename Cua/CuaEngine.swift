import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – Cua engine (tool call bodies; all in-memory)
struct ToolFailure: Error {
    let result: [String: Any]
}

final class CuaEngine {
    static let shared = CuaEngine()

    // MARK: – parameter parsing (never trap on hostile JSON numbers)
    private func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double, d.isFinite { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }
    private func pDouble(_ params: [String: Any], _ key: String) -> Double? {
        guard let d = number(params[key]), d.isFinite else { return nil }
        return d
    }
    private func pInt(_ params: [String: Any], _ key: String) -> Int? {
        guard let d = pDouble(params, key) else { return nil }
        return Int(exactly: d)
    }
    private func pUInt32(_ params: [String: Any], _ key: String) -> UInt32? {
        guard let d = pDouble(params, key), d >= 0, d <= Double(UInt32.max) else { return nil }
        return UInt32(d)
    }
    private func pUInt16(_ params: [String: Any], _ key: String) -> UInt16? {
        guard let d = pDouble(params, key), d >= 0, d <= Double(UInt16.max) else { return nil }
        return UInt16(d)
    }
    private func pInt32(_ params: [String: Any], _ key: String) -> Int32? {
        guard let d = pDouble(params, key), d >= Double(Int32.min), d <= Double(Int32.max) else { return nil }
        return Int32(d)
    }
    private func pString(_ params: [String: Any], _ key: String) -> String? {
        (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func clampInt(_ v: Int?, _ lo: Int, _ hi: Int, _ fallback: Int) -> Int {
        guard let v = v else { return fallback }
        return max(lo, min(hi, v))
    }
    private func clampDouble(_ v: Double?, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
        guard let v = v, v.isFinite else { return fallback }
        return max(lo, min(hi, v))
    }

    private func jsonText(_ obj: [String: Any]) -> String {
        String(decoding: jsonData(obj), as: UTF8.self)
    }
    private func errorResult(_ code: String, _ message: String, hint: String? = nil,
                             extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = ["code": code, "message": message]
        if let hint = hint { p["hint"] = hint }
        for (k, v) in extra { p[k] = v }
        return toolResultText(jsonText(p), isError: true, structured: p)
    }
    private func failure(_ code: String, _ message: String, hint: String? = nil,
                         extra: [String: Any] = [:]) -> ToolFailure {
        ToolFailure(result: errorResult(code, message, hint: hint, extra: extra))
    }
    private func globalActiveFailure() -> ToolFailure {
        let status = ForegroundCoordinator.shared.status()
        return failure("GLOBAL_FOREGROUND_ACTIVE",
                       "Another agent is using the foreground pointer and focus.",
                       hint: "End your turn or do work that does not use the desktop. Acquire a new lease after the foreground grant ends.",
                       extra: ["retryable": true, "suggested": "end_turn_or_non_desktop_work", "foreground": status])
    }
    // MARK: – target resolution
    func resolvePid(params: [String: Any]) -> Int32? {
        if let n = pInt(params, "pid") {
            guard n >= 0, n <= Int(Int32.max) else { return nil }
            return Int32(n)
        }
        if let s = pString(params, "app"), !s.isEmpty { return findPid(app: s) }
        if let s = pString(params, "pid"), let n = Int32(s) { return n }
        return nil
    }

    private func leaseErrorResult(_ e: SessionStore.LeaseError) -> [String: Any] {
        switch e {
        case .held(let s): return leaseHeldResult(s)
        case .invalidId(let reason): return invalidIdResult(reason)
        case .unknownApp(let m): return errorResult("UNKNOWN_APP", m)
        case .badRequest(let m): return errorResult("BAD_ARGS", m)
        }
    }

    private func foregroundObservationFailure(_ s: Session) -> [String: Any]? {
        guard s.scope == .foreground else { return nil }
        let state = ForegroundCoordinator.shared.observationStatus()
        if state.needsScreenshot {
            return errorResult("SCREENSHOT_REQUIRED",
                               "take a screenshot before acting in foreground",
                               hint: "Call screenshot with this acquisitionId.")
        }
        if state.dirty {
            return errorResult("STALE_OBSERVATION",
                               "the screen changed after your last screenshot",
                               hint: "Take a new screenshot before acting.")
        }
        return nil
    }

    func requireLease(params: [String: Any]) -> Result<Session, ToolFailure> {
        guard let id = pString(params, "acquisitionId"), !id.isEmpty else {
            return .failure(ToolFailure(result: invalidIdResult("missing acquisitionId — call acquire first")))
        }
        if let active = ForegroundCoordinator.shared.activeSessionID,
           id.lowercased() != active.lowercased() {
            return .failure(globalActiveFailure())
        }
        switch SessionStore.shared.validate(id: id) {
        case .success(let s):
            if ForegroundCoordinator.shared.activeSessionID == nil && s.scope == .foreground {
                return .failure(ToolFailure(result: invalidIdResult("foreground grant is no longer active")))
            }
            return .success(s)
        case .failure(let e):
            return .failure(ToolFailure(result: leaseErrorResult(e)))
        }
    }

    struct Target {
        let wid: UInt32
        let bounds: CGRect
        let isScreen: Bool
    }

    func resolveTarget(_ s: Session, _ params: [String: Any], allowScreen: Bool) -> Result<Target, ToolFailure> {
        let requested = pUInt32(params, "wid")
        if s.scope == .foreground {
            if let requested = requested, requested != 0 {
                guard let b = windowBounds(wid: requested) else {
                    return .failure(failure("WINDOW_GONE", "window \(requested) is no longer available"))
                }
                return .success(Target(wid: requested, bounds: b, isScreen: false))
            }
            let b = CGDisplayBounds(CGMainDisplayID())
            guard b.width > 0, b.height > 0 else {
                return .failure(failure("NO_DISPLAY", "no active display"))
            }
            return .success(Target(wid: 0, bounds: b, isScreen: true))
        }
        if s.scope != .app {
            guard let leased = s.wid else { return .failure(failure("NO_WINDOW", "lease has no window")) }
            if let requested = requested, requested != leased {
                return .failure(failure("WINDOW_NOT_LEASED", "this lease owns window \(leased), not \(requested)"))
            }
            guard let b = windowBounds(wid: leased) else {
                return .failure(failure("WINDOW_GONE", "the leased window is no longer available"))
            }
            return .success(Target(wid: leased, bounds: b, isScreen: false))
        }
        let wid = requested ?? defaultWid(pid: s.pid) ?? 0
        if wid == 0 {
            if allowScreen {
                let b = CGDisplayBounds(CGMainDisplayID())
                guard b.width > 0, b.height > 0 else {
                    return .failure(failure("NO_DISPLAY", "no active display"))
                }
                return .success(Target(wid: 0, bounds: b, isScreen: true))
            }
            return .failure(failure("NO_WINDOW", "no window to target; pass wid or open a window"))
        }
        guard windowOwnerPid(wid: wid) == s.pid else {
            return .failure(failure("WINDOW_NOT_OWNED", "window \(wid) does not belong to pid \(s.pid)"))
        }
        guard let b = windowBounds(wid: wid) else {
            return .failure(failure("WINDOW_GONE", "window \(wid) is no longer available"))
        }
        return .success(Target(wid: wid, bounds: b, isScreen: false))
    }

    private func coordSpace(_ s: Session, _ params: [String: Any], fallback: CoordSpace? = nil) -> CoordSpace? {
        if let raw = pString(params, "coordSpace") {
            guard let c = CoordSpace(rawValue: raw) else { return nil }
            if c == .screen && s.scope == .window { return nil }
            return c
        }
        return fallback ?? s.coordSpace
    }

    struct MappedPoint {
        let screen: CGPoint
        let normalized: CGPoint
    }

    private func mapPoint(_ s: Session, target: Target, x: Double, y: Double,
                          space: CoordSpace) -> Result<MappedPoint, ToolFailure> {
        guard x.isFinite, y.isFinite else { return .failure(failure("BAD_COORDS", "coordinates must be finite")) }
        switch space {
        case .screen:
            guard s.scope == .app || s.scope == .foreground else {
                return .failure(failure("SCREEN_COORDS_FORBIDDEN", "absolute screen coordinates are only allowed for app and foreground leases"))
            }
            let nx = target.bounds.width > 0 ? (x - target.bounds.minX) / target.bounds.width : 0
            let ny = target.bounds.height > 0 ? (y - target.bounds.minY) / target.bounds.height : 0
            return .success(MappedPoint(screen: CGPoint(x: x, y: y), normalized: CGPoint(x: nx, y: ny)))
        case .norm1000:
            guard x >= 0, x <= 1000, y >= 0, y <= 1000 else {
                return .failure(failure("BAD_COORDS", "norm1000 coordinates must be in 0...1000",
                                        hint: "Use coordSpace:'image' for pixels or coordSpace:'screen' for absolute points."))
            }
            let nx = x / 1000.0, ny = y / 1000.0
            return .success(MappedPoint(screen: CGPoint(x: target.bounds.minX + nx * target.bounds.width,
                                                        y: target.bounds.minY + ny * target.bounds.height),
                                        normalized: CGPoint(x: nx, y: ny)))
        case .image:
            guard let snap = SnapshotStore.shared.get(sessionID: s.id, wid: target.wid) else {
                return .failure(failure("NO_SNAPSHOT", "image coordinates need a prior screenshot for this window",
                                        hint: "Call screenshot first, or use coordSpace:'norm1000'."))
            }
            guard x >= 0, x <= Double(snap.imageWidth), y >= 0, y <= Double(snap.imageHeight),
                  snap.imageWidth > 0, snap.imageHeight > 0 else {
                return .failure(failure("BAD_COORDS", "image coordinates must be in 0...\(snap.imageWidth) by 0...\(snap.imageHeight)"))
            }
            let nx = snap.region.minX + (x / Double(snap.imageWidth)) * snap.region.width
            let ny = snap.region.minY + (y / Double(snap.imageHeight)) * snap.region.height
            return .success(MappedPoint(screen: CGPoint(x: target.bounds.minX + nx * target.bounds.width,
                                                        y: target.bounds.minY + ny * target.bounds.height),
                                        normalized: CGPoint(x: nx, y: ny)))
        }
    }

    private func rawPoint(_ params: [String: Any]) -> (Double, Double)? {
        if let x = pDouble(params, "x"), let y = pDouble(params, "y") { return (x, y) }
        if let at = pString(params, "at") {
            let p = at.split(separator: ",")
            if p.count == 2, let x = Double(p[0].trimmingCharacters(in: .whitespaces)),
               let y = Double(p[1].trimmingCharacters(in: .whitespaces)), x.isFinite, y.isFinite {
                return (x, y)
            }
        }
        return nil
    }

    private func screenPoint(_ s: Session, target: Target, params: [String: Any],
                             space: CoordSpace) -> Result<MappedPoint, ToolFailure> {
        guard let (x, y) = rawPoint(params) else {
            return .failure(failure("BAD_ARGS", "pass x,y or at"))
        }
        return mapPoint(s, target: target, x: x, y: y, space: space)
    }

    private func normalizedFromScreen(_ p: CGPoint, bounds: CGRect) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: (p.x - bounds.minX) / bounds.width, y: (p.y - bounds.minY) / bounds.height)
    }

    // MARK: – snapshots
    private func parseRegion(_ params: [String: Any]) -> Result<CGRect, ToolFailure> {
        guard let raw = params["region"] else {
            return .success(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        var x = 0.0, y = 0.0, w = 1.0, h = 1.0
        if let s = raw as? String {
            let p = s.split(separator: ",")
            guard p.count == 4,
                  let vx = Double(p[0].trimmingCharacters(in: .whitespaces)),
                  let vy = Double(p[1].trimmingCharacters(in: .whitespaces)),
                  let vw = Double(p[2].trimmingCharacters(in: .whitespaces)),
                  let vh = Double(p[3].trimmingCharacters(in: .whitespaces)) else {
                return .failure(failure("BAD_REGION", "region must be x,y,w,h"))
            }
            x = vx; y = vy; w = vw; h = vh
        } else if let d = raw as? [String: Any] {
            guard let vx = number(d["x"]), let vy = number(d["y"]),
                  let vw = number(d["width"]), let vh = number(d["height"]) else {
                return .failure(failure("BAD_REGION", "region needs x, y, width, height"))
            }
            x = vx; y = vy; w = vw; h = vh
        } else {
            return .failure(failure("BAD_REGION", "region must be an object or string"))
        }
        guard x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0,
              x >= 0, y >= 0, x + w <= 1.0001, y + h <= 1.0001 else {
            return .failure(failure("BAD_REGION", "region must be normalized 0...1 and non-empty"))
        }
        return .success(CGRect(x: x, y: y, width: min(w, 1 - x), height: min(h, 1 - y)))
    }

    private func captureSnapshot(_ s: Session, target: Target, region: CGRect,
                                 maxDimension: Int, grid: Int,
                                 cursor: (Double, Double)?,
                                 space: CoordSpace? = nil) -> Result<(Snapshot, Data), ToolFailure> {
        let coord = space ?? s.coordSpace
        let source: CGImage?
        if target.wid == 0 { source = captureScreenImage() } else { source = captureWindowImage(wid: target.wid) }
        guard let source = source else {
            return .failure(failure("CAPTURE_FAILED",
                                    "could not capture \(target.wid == 0 ? "the display" : "window \(target.wid)")",
                                    hint: "Grant Screen Recording to Cua in Settings → Privacy & Security."))
        }
        guard let rendered = renderSnapshot(source: source, windowBounds: target.bounds, region: region,
                                             maxDimension: maxDimension, grid: grid,
                                             cursor: cursor, coordSpace: coord) else {
            return .failure(failure("RENDER_FAILED", "could not render the screenshot"))
        }
        guard let data = pngData(from: rendered.image) else {
            return .failure(failure("PNG_FAILED", "could not encode the screenshot"))
        }
        let snap = Snapshot(id: UUID().uuidString.prefix(8).lowercased(), sessionID: s.id, wid: target.wid,
                            source: source, windowBounds: target.bounds, region: region,
                            imageWidth: rendered.width, imageHeight: rendered.height,
                            coordSpace: coord, capturedAt: Date())
        SnapshotStore.shared.save(snap)
        return .success((snap, data))
    }

    private func snapshotPayload(_ snap: Snapshot, data: Data, pid: Int32) -> [String: Any] {
        let b = snap.windowBounds
        let scale = b.width > 0 && snap.region.width > 0
            ? Double(snap.imageWidth) / (Double(b.width) * Double(snap.region.width)) : 1
        let backing = b.width > 0 ? Double(snap.source.width) / Double(b.width) : 1
        return [
            "snapshotId": snap.id, "wid": Int(snap.wid), "pid": Int(pid), "bytes": data.count,
            "imageWidth": snap.imageWidth, "imageHeight": snap.imageHeight,
            "coordSpace": snap.coordSpace.rawValue,
            "scale": scale, "backingScale": backing,
            "window": ["x": Double(b.minX), "y": Double(b.minY), "width": Double(b.width), "height": Double(b.height)],
            "region": ["x": Double(snap.region.minX), "y": Double(snap.region.minY),
                       "width": Double(snap.region.width), "height": Double(snap.region.height)],
            "capturedAt": Int(snap.capturedAt.timeIntervalSince1970 * 1000)
        ]
    }

    // MARK: – tool bodies
    func toolListApps() -> [String: Any] {
        let sessions = SessionStore.shared.sessions()
        let apps = runningApps().map { a -> [String: Any] in
            let pid = Int32(intVal(a["pid"]))
            var d: [String: Any] = ["pid": Int(pid), "name": a["name"] as! String, "bid": a["bid"] as! String]
            if let h = sessions.first(where: { $0.pid == pid }) {
                d["held"] = true
                d["scope"] = h.scope.rawValue
                d["acquisitionId"] = h.id
                d["agent"] = h.agent ?? "unknown"
                if let wid = h.wid { d["wid"] = Int(wid) }
            } else { d["held"] = false }
            return d
        }
        let sessionPayload = sessions.map { s -> [String: Any] in
            var d: [String: Any] = ["pid": Int(s.pid), "app": s.appName, "bid": s.bid,
                                     "scope": s.scope.rawValue, "agent": s.agent ?? "unknown",
                                     "acquisitionId": s.id, "id": s.id,
                                     "coordSpace": s.coordSpace.rawValue]
            if let wid = s.wid {
                d["wid"] = Int(wid)
                if let title = windowTitle(wid: wid) { d["windowTitle"] = title }
            }
            return d
        }
        let payload: [String: Any] = ["apps": apps, "sessions": sessionPayload, "foreground": ForegroundCoordinator.shared.status()]
        return toolResultText(jsonText(payload), structured: payload)
    }

    func toolWindows(params: [String: Any]) -> [String: Any] {
        let pid = resolvePid(params: params)
        let list = windowList(pid: pid, onscreenOnly: !(params["all"] as? Bool ?? false))
        let slim = list.map { w -> [String: Any] in
            var d: [String: Any] = ["wid": intVal(w["wid"]), "pid": intVal(w["pid"]),
                                     "owner": w["owner"] as! String, "layer": intVal(w["layer"]),
                                     "bounds": w["bounds"] as! [String: Any]]
            if let wid = w["wid"] as? Int, let title = windowTitle(wid: UInt32(wid)) { d["title"] = title }
            return d
        }
        let payload: [String: Any] = ["windows": slim]
        return toolResultText(jsonText(payload), structured: payload)
    }

    func toolAcquire(params: [String: Any]) -> [String: Any] {
        guard let pid = resolvePid(params: params) else {
            return errorResult("NO_TARGET", "pass pid or app")
        }
        if ForegroundCoordinator.shared.isActive {
            return globalActiveFailure().result
        }
        if appNameForPid(pid) == "?" && defaultWid(pid: pid) == nil {
            return errorResult("NO_SUCH_PID", "no running app with that pid")
        }
        let scopeRaw = pString(params, "scope") ?? "app"
        guard let scope = LeaseScope(rawValue: scopeRaw), scope != .foreground else {
            return errorResult("BAD_ARGS", "scope must be app or window")
        }
        let spaceRaw = pString(params, "coordSpace") ?? CoordSpace.norm1000.rawValue
        guard let space = CoordSpace(rawValue: spaceRaw) else {
            return errorResult("BAD_ARGS", "coordSpace must be image, norm1000, or screen")
        }
        if scope == .window && space == .screen {
            return errorResult("BAD_ARGS", "window leases cannot use screen coordinates")
        }
        var wid: UInt32?
        if scope == .window {
            guard let requested = pUInt32(params, "wid"), requested != 0 else {
                return errorResult("BAD_ARGS", "window scope needs wid")
            }
            guard windowOwnerPid(wid: requested) == pid else {
                return errorResult("WINDOW_NOT_OWNED", "window \(requested) does not belong to pid \(pid)")
            }
            wid = requested
        }
        let agent = pString(params, "agent") ?? "agent"
        switch SessionStore.shared.acquire(pid: pid, scope: scope, wid: wid, coordSpace: space, agent: agent) {
        case .success(let s):
            var payload: [String: Any] = ["acquisitionId": s.id, "pid": Int(s.pid), "app": s.appName,
                                           "scope": s.scope.rawValue, "coordSpace": s.coordSpace.rawValue]
            if let wid = s.wid {
                payload["wid"] = Int(wid)
                if let title = s.windowTitle { payload["windowTitle"] = title }
            }
            return toolResultText(jsonText(payload), structured: payload)
        case .failure(let e):
            return leaseErrorResult(e)
        }
    }

    func toolRelease(params: [String: Any]) -> [String: Any] {
        guard let id = pString(params, "acquisitionId"), !id.isEmpty else {
            return invalidIdResult("missing acquisitionId")
        }
        guard let session = SessionStore.shared.find(id: id) else {
            return invalidIdResult("no active lease with this acquisitionId")
        }
        if session.scope == .foreground {
            _ = ForegroundCoordinator.shared.release(sessionID: session.id)
        } else {
            _ = SessionStore.shared.release(id: session.id)
        }
        SnapshotStore.shared.remove(sessionID: session.id)
        AXIndexStore.shared.remove(sessionID: session.id)
        return toolResultText("{\"ok\":true}")
    }

    func toolScreenshot(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        let space: CoordSpace
        switch coordSpace(s, params) {
        case .some(let v): space = v
        case .none: return errorResult("BAD_ARGS", "invalid coordSpace")
        }
        let target: Target
        switch resolveTarget(s, params, allowScreen: true) {
        case .success(let value): target = value
        case .failure(let f): return f.result
        }
        let region: CGRect
        switch parseRegion(params) {
        case .success(let r): region = r
        case .failure(let f): return f.result
        }
        let grid = clampInt(pInt(params, "grid"), 0, 1000, 0)
        let maxDim = clampInt(pInt(params, "maxDimension"), 64, 2560, 2560)
        var cursor: CGPoint? = nil
        if let raw = pString(params, "cursor") {
            if raw == "last" || raw == "show" {
                if let c = SessionStore.shared.lastCursor(sessionID: s.id, wid: target.wid) {
                    cursor = CGPoint(x: c.0, y: c.1)
                }
            } else {
                let pair = raw.split(separator: ",")
                if pair.count == 2, let x = Double(pair[0].trimmingCharacters(in: .whitespaces)),
                   let y = Double(pair[1].trimmingCharacters(in: .whitespaces)),
                   let mapped = try? mapPoint(s, target: target, x: x, y: y, space: space).get() {
                    cursor = mapped.screen
                }
            }
        }
        let cursorTuple = cursor.map { (Double($0.x), Double($0.y)) }
        let captured: Result<(Snapshot, Data), ToolFailure> = captureSnapshot(s, target: target, region: region,
                                                                              maxDimension: maxDim, grid: grid,
                                                                              cursor: cursorTuple, space: space)
        let snap: Snapshot, data: Data
        switch captured {
        case .success(let value): snap = value.0; data = value.1
        case .failure(let f): return f.result
        }
        let payload = snapshotPayload(snap, data: data, pid: s.pid)
        if s.scope == .foreground { ForegroundCoordinator.shared.noteObservation() }
        let caption = "screenshot wid=\(target.wid) image=\(snap.imageWidth)x\(snap.imageHeight) space=\(space.rawValue) bytes=\(data.count)"
        return toolResultImage(png: data, caption: caption, structured: payload)
    }

    private func sourceForZoom(_ s: Session, target: Target) -> CGImage? {
        if s.scope == .foreground {
            let observation = ForegroundCoordinator.shared.observationStatus()
            if observation.needsScreenshot || observation.dirty {
                return target.wid == 0 ? captureScreenImage() : captureWindowImage(wid: target.wid)
            }
        }
        if let snap = SnapshotStore.shared.get(sessionID: s.id, wid: target.wid) { return snap.source }
        return target.wid == 0 ? captureScreenImage() : captureWindowImage(wid: target.wid)
    }

    func toolZoom(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        let space: CoordSpace
        switch coordSpace(s, params) {
        case .some(let v): space = v
        case .none: return errorResult("BAD_ARGS", "invalid coordSpace")
        }
        let target: Target
        switch resolveTarget(s, params, allowScreen: true) {
        case .success(let value): target = value
        case .failure(let f): return f.result
        }
        let part = (pString(params, "part") ?? "").lowercased()
        let size = clampDouble(pDouble(params, "size"), 0.1, 1.0, part == "cursor" ? 0.25 : 0.5)
        var center = CGPoint(x: 0.5, y: 0.5)
        if part == "cursor", let c = SessionStore.shared.lastCursor(sessionID: s.id, wid: target.wid) {
            center = normalizedFromScreen(CGPoint(x: c.0, y: c.1), bounds: target.bounds)
        } else if part == "top-left" || part == "tl" { center = CGPoint(x: 0.25, y: 0.25) }
        else if part == "top-right" || part == "tr" { center = CGPoint(x: 0.75, y: 0.25) }
        else if part == "bottom-left" || part == "bl" { center = CGPoint(x: 0.25, y: 0.75) }
        else if part == "bottom-right" || part == "br" { center = CGPoint(x: 0.75, y: 0.75) }
        else if part == "center" { center = CGPoint(x: 0.5, y: 0.5) }
        else if !part.isEmpty { return errorResult("BAD_ARGS", "part must be top-left, top-right, bottom-left, bottom-right, center, or cursor") }
        if let (x, y) = rawPoint(params) {
            switch mapPoint(s, target: target, x: x, y: y, space: space) {
            case .success(let p): center = p.normalized
            case .failure(let f): return f.result
            }
        }
        var region = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        region = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let source = sourceForZoom(s, target: target) else {
            return errorResult("CAPTURE_FAILED", "could not capture the window",
                               extra: ["hint": "Grant Screen Recording to Cua."])
        }
        let maxDim = clampInt(pInt(params, "maxDimension"), 64, 2560, 2560)
        guard let rendered = renderSnapshot(source: source, windowBounds: target.bounds, region: region,
                                             maxDimension: maxDim, grid: 0, cursor: nil,
                                             coordSpace: space),
              let data = pngData(from: rendered.image) else {
            return errorResult("RENDER_FAILED", "could not render zoom")
        }
        let snap = Snapshot(id: UUID().uuidString.prefix(8).lowercased(), sessionID: s.id, wid: target.wid,
                            source: source, windowBounds: target.bounds, region: region,
                            imageWidth: rendered.width, imageHeight: rendered.height,
                            coordSpace: space, capturedAt: Date())
        SnapshotStore.shared.save(snap)
        let payload = snapshotPayload(snap, data: data, pid: s.pid)
        let caption = "zoom wid=\(target.wid) part=\(part.isEmpty ? "at" : part) image=\(rendered.width)x\(rendered.height) bytes=\(data.count)"
        return toolResultImage(png: data, caption: caption, structured: payload)
    }

    func toolMove(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        let space: CoordSpace
        switch coordSpace(s, params) {
        case .some(let v): space = v
        case .none: return errorResult("BAD_ARGS", "invalid coordSpace")
        }
        let target: Target
        switch resolveTarget(s, params, allowScreen: true) {
        case .success(let value): target = value
        case .failure(let f): return f.result
        }
        let mapped: MappedPoint
        if let (x, y) = rawPoint(params) {
            switch mapPoint(s, target: target, x: x, y: y, space: space) {
            case .success(let p): mapped = p
            case .failure(let f): return f.result
            }
        } else if let c = SessionStore.shared.lastCursor(sessionID: s.id, wid: target.wid) {
            mapped = MappedPoint(screen: CGPoint(x: c.0, y: c.1), normalized: normalizedFromScreen(CGPoint(x: c.0, y: c.1), bounds: target.bounds))
        } else {
            return errorResult("BAD_ARGS", "pass x,y or at")
        }
        SessionStore.shared.saveCursor(sessionID: s.id, wid: target.wid, x: Double(mapped.screen.x), y: Double(mapped.screen.y))
        let grid = clampInt(pInt(params, "grid"), 0, 1000, 0)
        let captured = captureSnapshot(s, target: target, region: CGRect(x: 0, y: 0, width: 1, height: 1),
                                       maxDimension: 2560, grid: grid,
                                       cursor: (Double(mapped.screen.x), Double(mapped.screen.y)),
                                       space: space)
        let snap: Snapshot, data: Data
        switch captured {
        case .success(let value): snap = value.0; data = value.1
        case .failure(let f): return f.result
        }
        var payload = snapshotPayload(snap, data: data, pid: s.pid)
        payload["cursor"] = [Int(mapped.screen.x), Int(mapped.screen.y)]
        payload["coordSpace"] = space.rawValue
        return toolResultImage(png: data, caption: "cursor=\(Int(mapped.screen.x)),\(Int(mapped.screen.y)) wid=\(target.wid)",
                               structured: payload)
    }

    func toolHover(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        if let f = foregroundObservationFailure(s) { return f }
        let space: CoordSpace
        switch coordSpace(s, params) {
        case .some(let v): space = v
        case .none: return errorResult("BAD_ARGS", "invalid coordSpace")
        }
        let target: Target
        switch resolveTarget(s, params, allowScreen: false) {
        case .success(let value): target = value
        case .failure(let f): return f.result
        }
        let mapped: MappedPoint
        if let (x, y) = rawPoint(params) {
            switch mapPoint(s, target: target, x: x, y: y, space: space) {
            case .success(let p): mapped = p
            case .failure(let f): return f.result
            }
        } else if let c = SessionStore.shared.lastCursor(sessionID: s.id, wid: target.wid) {
            mapped = MappedPoint(screen: CGPoint(x: c.0, y: c.1), normalized: normalizedFromScreen(CGPoint(x: c.0, y: c.1), bounds: target.bounds))
        } else {
            return errorResult("BAD_ARGS", "pass x,y or at, or move the cursor first")
        }
        let foreground = s.scope == .foreground
        let bg = !foreground
        let local = CGPoint(x: mapped.screen.x - target.bounds.minX, y: mapped.screen.y - target.bounds.minY)
        let group = Int64(Date().timeIntervalSince1970 * 1000) % 100000
        if foreground {
            warpCursor(to: mapped.screen)
            postMouseMoved(pid: s.pid, wid: target.wid, local: local, screen: mapped.screen, bg: false, group: group)
        } else {
            postMouseMoved(pid: s.pid, wid: target.wid, local: local, screen: mapped.screen, bg: bg, group: group)
        }
        usleep(80_000)
        SessionStore.shared.saveCursor(sessionID: s.id, wid: target.wid, x: Double(mapped.screen.x), y: Double(mapped.screen.y))
        let grid = clampInt(pInt(params, "grid"), 0, 1000, 0)
        let captured = captureSnapshot(s, target: target, region: CGRect(x: 0, y: 0, width: 1, height: 1),
                                       maxDimension: 2560, grid: grid,
                                       cursor: (Double(mapped.screen.x), Double(mapped.screen.y)),
                                       space: space)
        let snap: Snapshot, data: Data
        switch captured {
        case .success(let value): snap = value.0; data = value.1
        case .failure(let f): return f.result
        }
        var payload = snapshotPayload(snap, data: data, pid: s.pid)
        payload["hover"] = true
        payload["cursor"] = [Int(mapped.screen.x), Int(mapped.screen.y)]
        payload["coordSpace"] = space.rawValue
        return toolResultImage(png: data, caption: "hover=\(Int(mapped.screen.x)),\(Int(mapped.screen.y)) wid=\(target.wid)",
                               structured: payload)
    }

    func toolClick(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        if let f = foregroundObservationFailure(s) { return f }
        let space: CoordSpace
        switch coordSpace(s, params) {
        case .some(let v): space = v
        case .none: return errorResult("BAD_ARGS", "invalid coordSpace")
        }
        let target: Target
        switch resolveTarget(s, params, allowScreen: false) {
        case .success(let value): target = value
        case .failure(let f): return f.result
        }
        let mapped: MappedPoint
        switch screenPoint(s, target: target, params: params, space: space) {
        case .success(let p): mapped = p
        case .failure(let f): return f.result
        }
        let foreground = s.scope == .foreground
        let bg = !foreground
        let dbl = params["double"] as? Bool ?? false
        let right = params["right"] as? Bool ?? false
        let local = CGPoint(x: mapped.screen.x - target.bounds.minX, y: mapped.screen.y - target.bounds.minY)
        let group = Int64(Date().timeIntervalSince1970 * 1000) % 100000

        func send() {
            if foreground { warpCursor(to: mapped.screen) }
            let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
                right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
            let clicks = dbl ? 2 : 1
            for i in 0..<clicks {
                guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                         mouseCursorPosition: mapped.screen, mouseButton: button),
                      let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                                       mouseCursorPosition: mapped.screen, mouseButton: button) else { continue }
                if bg {
                    routeMouse(down, wid: target.wid, pid: s.pid, local: local, clickState: Int64(i + 1), group: group)
                    routeMouse(up, wid: target.wid, pid: s.pid, local: local, clickState: Int64(i + 1), group: group)
                    postToPid(down, pid: s.pid); usleep(30_000); postToPid(up, pid: s.pid)
                } else {
                    down.post(tap: .cghidEventTap); usleep(30_000); up.post(tap: .cghidEventTap)
                }
                if dbl && i == 0 { usleep(80_000) }
            }
        }
        send()
        SessionStore.shared.saveCursor(sessionID: s.id, wid: target.wid, x: Double(mapped.screen.x), y: Double(mapped.screen.y))
        var payload: [String: Any] = ["ok": true, "scope": s.scope.rawValue,
                                       "at": [Int(mapped.screen.x), Int(mapped.screen.y)],
                                       "wid": Int(target.wid), "pid": Int(s.pid), "coordSpace": space.rawValue]
        if foreground { payload["foreground"] = true }
        return toolResultText(jsonText(payload), structured: payload)
    }

    func toolType(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        if let f = foregroundObservationFailure(s) { return f }
        guard let text = params["text"] as? String else { return errorResult("BAD_ARGS", "pass text") }
        let foreground = s.scope == .foreground
        let bg = !foreground
        let work = { typeText(text, pid: s.pid, bg: bg) }
        work()
        var payload: [String: Any] = ["ok": true, "typed": text.count, "scope": s.scope.rawValue]
        if foreground { payload["foreground"] = true }
        return toolResultText(jsonText(payload), structured: payload)
    }

    func toolKey(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        if let f = foregroundObservationFailure(s) { return f }
        guard let code = pUInt16(params, "code") else { return errorResult("BAD_ARGS", "pass a valid key code 0...65535") }
        let foreground = s.scope == .foreground
        let bg = !foreground
        let hold = clampInt(pInt(params, "holdMs"), 0, 10_000, bg ? 300 : 50)
        var flags: CGEventFlags = []
        if params["shift"] as? Bool ?? false { flags.insert(.maskShift) }
        if params["ctrl"] as? Bool ?? false { flags.insert(.maskControl) }
        if params["alt"] as? Bool ?? false { flags.insert(.maskAlternate) }
        if params["cmd"] as? Bool ?? false { flags.insert(.maskCommand) }
        if params["fn"] as? Bool ?? false { flags.insert(.maskSecondaryFn) }
        let chr = params["char"] as? String
        let work = { postKey(code, pid: s.pid, bg: bg, holdMs: hold, flags: flags, char: chr) }
        work()
        var payload: [String: Any] = ["ok": true, "code": Int(code), "hold_ms": hold]
        if let chr = chr { payload["char"] = chr }
        if foreground { payload["foreground"] = true }
        return toolResultText(jsonText(payload), structured: payload)
    }

    func toolScroll(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        if let f = foregroundObservationFailure(s) { return f }
        let space: CoordSpace
        switch coordSpace(s, params) {
        case .some(let v): space = v
        case .none: return errorResult("BAD_ARGS", "invalid coordSpace")
        }
        let target: Target
        switch resolveTarget(s, params, allowScreen: false) {
        case .success(let value): target = value
        case .failure(let f): return f.result
        }
        let mapped: MappedPoint
        switch screenPoint(s, target: target, params: params, space: space) {
        case .success(let p): mapped = p
        case .failure(let f): return f.result
        }
        let dx = pInt32(params, "dx") ?? 0
        let dy = pInt32(params, "dy") ?? 0
        let foreground = s.scope == .foreground
        let bg = !foreground
        let local = CGPoint(x: mapped.screen.x - target.bounds.minX, y: mapped.screen.y - target.bounds.minY)
        let work = {
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            e.location = mapped.screen
            if bg {
                routeMouse(e, wid: target.wid, pid: s.pid, local: local, clickState: 0, group: 0)
                postToPid(e, pid: s.pid)
            } else {
                e.post(tap: .cghidEventTap)
            }
        }
        if foreground { warpCursor(to: mapped.screen) }
        work()
        var payload: [String: Any] = ["ok": true, "dx": Int(dx), "dy": Int(dy),
                                       "at": [Int(mapped.screen.x), Int(mapped.screen.y)], "coordSpace": space.rawValue]
        if foreground { payload["foreground"] = true }
        return toolResultText(jsonText(payload), structured: payload)
    }

    func toolDrag(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        if let f = foregroundObservationFailure(s) { return f }
        let space: CoordSpace
        switch coordSpace(s, params) {
        case .some(let v): space = v
        case .none: return errorResult("BAD_ARGS", "invalid coordSpace")
        }
        let target: Target
        switch resolveTarget(s, params, allowScreen: false) {
        case .success(let value): target = value
        case .failure(let f): return f.result
        }
        func parsePoint(_ prefix: String) -> (Double, Double)? {
            if let x = pDouble(params, prefix + "X"), let y = pDouble(params, prefix + "Y") { return (x, y) }
            if let raw = pString(params, prefix) {
                let p = raw.split(separator: ",")
                if p.count == 2, let x = Double(p[0].trimmingCharacters(in: .whitespaces)),
                   let y = Double(p[1].trimmingCharacters(in: .whitespaces)) { return (x, y) }
            }
            return nil
        }
        guard let fromRaw = parsePoint("from"), let toRaw = parsePoint("to") else {
            return errorResult("BAD_ARGS", "pass fromX/fromY + toX/toY or from/to")
        }
        let from: MappedPoint, to: MappedPoint
        switch mapPoint(s, target: target, x: fromRaw.0, y: fromRaw.1, space: space) {
        case .success(let p): from = p
        case .failure(let f): return f.result
        }
        switch mapPoint(s, target: target, x: toRaw.0, y: toRaw.1, space: space) {
        case .success(let p): to = p
        case .failure(let f): return f.result
        }
        let foreground = s.scope == .foreground
        let bg = !foreground
        let steps = clampInt(pInt(params, "steps"), 1, 120, 12)
        let stepMs = clampInt(pInt(params, "stepMs"), 1, 200, 15)
        let startHold = clampInt(pInt(params, "startHoldMs"), 0, 2000, 0)
        let endHold = clampInt(pInt(params, "endHoldMs"), 0, 2000, 0)
        let group = Int64(Date().timeIntervalSince1970 * 1000) % 100000

        func event(_ type: CGEventType, _ p: CGPoint) -> CGEvent? {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return nil }
            if bg {
                let local = CGPoint(x: p.x - target.bounds.minX, y: p.y - target.bounds.minY)
                routeMouse(e, wid: target.wid, pid: s.pid, local: local, clickState: 1, group: group)
            }
            return e
        }
        func send(_ e: CGEvent) {
            if bg { postToPid(e, pid: s.pid) } else { e.post(tap: .cghidEventTap) }
        }
        let work = {
            if foreground { warpCursor(to: from.screen) }
            if let d = event(.leftMouseDown, from.screen) { send(d) }
            if startHold > 0 { usleep(UInt32(startHold * 1000)) }
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let p = CGPoint(x: from.screen.x + (to.screen.x - from.screen.x) * t,
                                y: from.screen.y + (to.screen.y - from.screen.y) * t)
                if let e = event(.leftMouseDragged, p) { send(e) }
                usleep(UInt32(stepMs * 1000))
            }
            if endHold > 0 { usleep(UInt32(endHold * 1000)) }
            if let u = event(.leftMouseUp, to.screen) { send(u) }
        }
        work()
        SessionStore.shared.saveCursor(sessionID: s.id, wid: target.wid, x: Double(to.screen.x), y: Double(to.screen.y))
        var payload: [String: Any] = ["ok": true, "steps": steps,
                                       "from": [Int(from.screen.x), Int(from.screen.y)],
                                       "to": [Int(to.screen.x), Int(to.screen.y)],
                                       "coordSpace": space.rawValue]
        if foreground { payload["foreground"] = true }
        return toolResultText(jsonText(payload), structured: payload)
    }

    func toolAx(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        let depth = clampInt(pInt(params, "depth"), 1, 64, 8)
        let limit = clampInt(pInt(params, "maxNodes"), 1, 20_000, 4000)
        let pid: Int32
        var wid: UInt32? = nil
        if s.scope == .window {
            pid = s.pid
            wid = s.wid
        } else if s.scope == .foreground {
            guard let requested = pUInt32(params, "wid"), requested != 0,
                  let owner = windowOwnerPid(wid: requested) else {
                return errorResult("NO_TARGET", "foreground AX needs a window id")
            }
            pid = owner
            wid = requested
        } else {
            pid = s.pid
            if let requested = pUInt32(params, "wid"), requested != 0 { wid = requested }
        }
        guard let text = axDump(sessionID: s.id, pid: pid, wid: wid, maxDepth: depth, limit: limit) else {
            return errorResult("AX_UNAVAILABLE", "could not read the accessibility tree",
                               extra: ["hint": "Grant Accessibility to Cua and make sure the window still exists."])
        }
        return toolResultText(text)
    }

    func toolPress(params: [String: Any]) -> [String: Any] {
        let s: Session
        switch requireLease(params: params) {
        case .success(let value): s = value
        case .failure(let f): return f.result
        }
        if let f = foregroundObservationFailure(s) { return f }
        guard let idx = pInt(params, "index") else { return errorResult("BAD_ARGS", "pass index") }
        let depth = clampInt(pInt(params, "depth"), 1, 64, 8)
        let limit = clampInt(pInt(params, "maxNodes"), 1, 20_000, 4000)
        let pid: Int32
        var wid: UInt32? = nil
        if s.scope == .window {
            pid = s.pid
            wid = s.wid
        } else if s.scope == .foreground {
            guard let requested = pUInt32(params, "wid"), requested != 0,
                  let owner = windowOwnerPid(wid: requested) else {
                return errorResult("NO_TARGET", "foreground AX needs a window id")
            }
            pid = owner
            wid = requested
        } else {
            pid = s.pid
            if let requested = pUInt32(params, "wid"), requested != 0 { wid = requested }
        }
        guard AXIndexStore.shared.build(sessionID: s.id, pid: pid, wid: wid, maxDepth: depth, limit: limit),
              let (nodes, _) = AXIndexStore.shared.nodes(sessionID: s.id) else {
            return errorResult("AX_UNAVAILABLE", "could not build the accessibility tree")
        }
        guard idx >= 0, idx < nodes.count else {
            return errorResult("BAD_INDEX", "index \(idx) is out of range 0...\(max(0, nodes.count - 1))")
        }
        let n = nodes[idx]
        if let wantRole = pString(params, "expectRole"), wantRole != n.role {
            return errorResult("GUARD_ROLE", "index \(idx) is \(n.role), expected \(wantRole)")
        }
        if let wantTitle = pString(params, "expectTitle"), !n.title.localizedCaseInsensitiveContains(wantTitle) {
            return errorResult("GUARD_TITLE", "title mismatch at index \(idx)")
        }
        let r = AXUIElementPerformAction(n.ref, kAXPressAction as CFString)
        let payload: [String: Any] = ["ok": r == .success, "index": idx, "role": n.role,
                                       "title": String(n.title.prefix(60)), "ax_error": r.rawValue]
        return toolResultText(jsonText(payload), isError: r != .success, structured: payload)
    }

    func toolRequestForeground(params: [String: Any]) -> [String: Any] {
        if ForegroundCoordinator.shared.isActive {
            return globalActiveFailure().result
        }
        let spaceRaw = pString(params, "coordSpace") ?? CoordSpace.screen.rawValue
        guard let space = CoordSpace(rawValue: spaceRaw) else {
            return errorResult("BAD_ARGS", "coordSpace must be image, norm1000, or screen")
        }
        let reason = String((pString(params, "reason") ?? "Full control requested").prefix(160))
        let agent = pString(params, "agent") ?? "agent"
        do {
            let grant = try ForegroundCoordinator.shared.request(agent: agent, reason: reason,
                                                                  coordSpace: space)
            let payload: [String: Any] = ["ok": true, "foregroundGrantId": grant,
                                           "acquisitionId": grant,
                                           "app": "This Mac", "coordSpace": space.rawValue]
            return toolResultText(jsonText(payload), structured: payload)
        } catch ForegroundRequestError.busy {
            return globalActiveFailure().result
        } catch ForegroundRequestError.denied {
            return errorResult("FOREGROUND_DENIED", "the user denied the foreground request",
                               extra: ["suggested": "keep working in the background or end your turn"])
        } catch ForegroundRequestError.timeout {
            return errorResult("FOREGROUND_TIMEOUT", "the user did not approve the foreground request in time",
                               extra: ["retryable": true])
        } catch {
            return errorResult("FOREGROUND_FAILED", "could not enter foreground mode")
        }
    }

    func toolForegroundStatus(params: [String: Any]) -> [String: Any] {
        let payload = ForegroundCoordinator.shared.status()
        return toolResultText(jsonText(payload), structured: payload)
    }

    func dispatch(tool: String, params: [String: Any]) -> [String: Any] {
        switch tool {
        case "list_apps": return toolListApps()
        case "windows": return toolWindows(params: params)
        case "acquire": return toolAcquire(params: params)
        case "release": return toolRelease(params: params)
        case "screenshot": return toolScreenshot(params: params)
        case "zoom": return toolZoom(params: params)
        case "move": return toolMove(params: params)
        case "hover": return toolHover(params: params)
        case "click": return toolClick(params: params)
        case "type": return toolType(params: params)
        case "key": return toolKey(params: params)
        case "scroll": return toolScroll(params: params)
        case "drag": return toolDrag(params: params)
        case "ax": return toolAx(params: params)
        case "press": return toolPress(params: params)
        case "request_foreground": return toolRequestForeground(params: params)
        case "foreground_status": return toolForegroundStatus(params: params)
        default: return errorResult("NO_SUCH_TOOL", "tool \(tool) does not exist")
        }
    }
}
