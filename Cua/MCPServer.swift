import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: - MCP helpers (JSON-RPC over HTTP)
func jsonData(_ obj: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
}
func toolResultText(_ text: String, isError: Bool = false, structured: [String: Any]? = nil) -> [String: Any] {
    var r: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
    if let structured = structured { r["structuredContent"] = structured }
    return r
}
func toolResultImage(png: Data, caption: String, structured: [String: Any]? = nil) -> [String: Any] {
    let b64 = png.base64EncodedString()
    let content: [[String: Any]] = [
        ["type": "text", "text": caption],
        ["type": "image", "data": b64, "mimeType": "image/png"]
    ]
    var r: [String: Any] = ["content": content, "isError": false]
    if let structured = structured { r["structuredContent"] = structured }
    _ = content
    return r
}
// MARK: - MCP tool definitions (served by tools/list)
func toolDefs() -> [[String: Any]] {
    func obj(_ props: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    let pidProp: [String: Any] = ["type": "number", "description": "Target pid"]
    let appProp: [String: Any] = ["type": "string", "description": "App name or bundle id (alternative to pid)"]
    let idProp: [String: Any] = ["type": "string", "description": "acquisitionId from acquire — required on every call after acquire"]
    let widProp: [String: Any] = ["type": "number", "description": "Window id. App leases default to the main window; window leases are fixed to their wid."]
    let coordProp: [String: Any] = ["type": "string", "enum": ["image", "norm1000", "screen"],
                                   "description": "Coordinate space. Lease default is set by acquire (norm1000 unless overridden). image = pixels in the last screenshot/zoom; norm1000 = 0...1000 window-relative; screen = absolute points (app/foreground leases only)."]
    let regionProp: [String: Any] = ["type": "object", "description": "Normalized crop {x,y,width,height} in 0...1 relative to the window; defaults to the full window."]
    return [
        ["name": "list_apps", "description": "List running apps, held leases, foreground state, and coordinate-space defaults.", "inputSchema": obj([:], required: [])],
        ["name": "windows", "description": "List windows (optionally for one pid/app).", "inputSchema": obj(["pid": pidProp, "app": appProp, "all": ["type": "boolean"]], required: [])],
        ["name": "acquire", "description": "Acquire an app lease (default) or a window lease. Returns acquisitionId plus the coordinate space and window target. App and window leases for one pid are mutually exclusive; multiple window leases may coexist. Fails with LEASE_HELD if the target is held.", "inputSchema": obj(["pid": pidProp, "app": appProp, "scope": ["type": "string", "enum": ["app", "window"], "description": "app (default) or window"], "wid": widProp, "coordSpace": coordProp, "agent": ["type": "string"]], required: [])],
        ["name": "release", "description": "Release an app/window/foreground lease.", "inputSchema": obj(["acquisitionId": idProp], required: ["acquisitionId"])],
        ["name": "screenshot", "description": "Capture a window (or the display when wid=0) as an inline PNG. Returns snapshotId, image dimensions, window bounds, crop region, scale, and coordinate space. Optional normalized region, grid, and cursor overlay.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "region": regionProp, "maxDimension": ["type": "number", "description": "Long-edge cap in pixels (default 2560; full-resolution source is cached for zoom)"], "grid": ["type": "number"], "cursor": ["type": "string", "description": "x,y in the lease coordinate space, or last"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "zoom", "description": "Return a clear crop of the target window or display, around a preset region or a point. part = top-left|top-right|bottom-left|bottom-right|center|cursor (cursor uses the lease's last agent cursor); at/x,y centers a crop. Crops the cached full-resolution screenshot without upscaling.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "part": ["type": "string", "enum": ["top-left", "top-right", "bottom-left", "bottom-right", "center", "cursor"]], "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "size": ["type": "number", "description": "Crop fraction 0.1...1.0 (default 0.5, or 0.25 for cursor)"], "maxDimension": ["type": "number", "description": "Long-edge cap in pixels (default 2560)"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "move", "description": "Set the lease's virtual cursor position and return a screenshot with the crosshair. Does not post a mouse event; use hover for that.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "grid": ["type": "number"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "hover", "description": "Move the agent pointer to a point in the target window or display without clicking. Posts a real mouseMoved so hover states and tooltips can appear, then returns a screenshot.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "grid": ["type": "number"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "click", "description": "Click at a point in the target window or display. Background leases post to the app process; foreground grants use the real HID path. Coordinates use the lease coordinate space unless coordSpace overrides.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "double": ["type": "boolean"], "right": ["type": "boolean"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "type", "description": "Type unicode text (keycode 0 + unicode; games need key). Foreground requires an approved grant.", "inputSchema": obj(["acquisitionId": idProp, "text": ["type": "string"]], required: ["acquisitionId", "text"])],
        ["name": "key", "description": "Virtual keycode (+modifiers, optional unicode char, hold ms). Foreground requires an approved grant.", "inputSchema": obj(["acquisitionId": idProp, "code": ["type": "number"], "shift": ["type": "boolean"], "ctrl": ["type": "boolean"], "alt": ["type": "boolean"], "cmd": ["type": "boolean"], "fn": ["type": "boolean"], "char": ["type": "string"], "holdMs": ["type": "number"]], required: ["acquisitionId", "code"])],
        ["name": "scroll", "description": "Pixel scroll at a point in the target window. Positive dy scrolls content up; dx/dy default to 0.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "dx": ["type": "number"], "dy": ["type": "number"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "drag", "description": "Left-button drag from one point to another. Supports steps, stepMs, startHoldMs, endHoldMs.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "fromX": ["type": "number"], "fromY": ["type": "number"], "toX": ["type": "number"], "toY": ["type": "number"], "from": ["type": "string"], "to": ["type": "string"], "steps": ["type": "number"], "stepMs": ["type": "number"], "startHoldMs": ["type": "number"], "endHoldMs": ["type": "number"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "ax", "description": "Accessibility tree dump for the lease target (positional index; same walk as press). Window leases walk only that window.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "depth": ["type": "number"], "maxNodes": ["type": "number"]], required: ["acquisitionId"])],
        ["name": "press", "description": "AXPress by positional index (guard with expectRole/expectTitle). Window leases act only inside that window.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "index": ["type": "number"], "depth": ["type": "number"], "maxNodes": ["type": "number"], "expectRole": ["type": "string"], "expectTitle": ["type": "string"]], required: ["acquisitionId", "index"])],
        ["name": "request_foreground", "description": "Ask the user to approve full control of this Mac (real pointer and keyboard). This blocks up to 120s for menubar approval, revokes every background lease on approval, and returns a foreground grant id. The grant runs until released or stopped.", "inputSchema": obj(["reason": ["type": "string"], "coordSpace": coordProp, "agent": ["type": "string"]], required: [])],
        ["name": "foreground_status", "description": "Return idle/pending/active foreground state and agent.", "inputSchema": obj([:], required: [])],
    ]
}

func leaseHeldResult(_ s: Session) -> [String: Any] {
    let payload: [String: Any] = [
        "code": "LEASE_HELD",
        "pid": s.pid,
        "app": s.appName,
        "holder": s.agent ?? "unknown",
        "hint": "This app is held by another agent. Ask the user to free this app's lease in the Cua menubar UI, then acquire again."
    ]
    let text = (try? JSONSerialization.data(withJSONObject: payload))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{\"code\":\"LEASE_HELD\"}"
    return toolResultText(text, isError: true, structured: payload)
}
func invalidIdResult(_ reason: String) -> [String: Any] {
    let payload: [String: Any] = ["code": "INVALID_ID", "reason": reason,
        "hint": "Invalid ID — call acquire for this app to register it (currently no agent owns it)."]
    let text = (try? JSONSerialization.data(withJSONObject: payload))?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } ?? "{\"code\":\"INVALID_ID\"}"
    return toolResultText(text, isError: true, structured: payload)
}

// MARK: – MCP HTTP server (Network framework, loopback only)
final class MCPServer: NSObject {
    static let shared = MCPServer()
    /// Injected into the menubar WKWebView only. It is deliberately not served
    /// over HTTP, so an MCP client cannot approve its own foreground request.
    let uiToken = UUID().uuidString
    // The listening socket and port are written on the main thread (start/stop, /api/port) and
    // read by the accept loop and the socket workers, so they are lock-backed. The generation
    // counter retires a superseded accept loop before it can accept on a recycled fd number.
    private let stateLock = NSLock()
    private var _listenFd: Int32 = -1
    private var _isRunning = false
    private var _acceptGeneration = 0
    var listenFd: Int32 {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _listenFd }
        set { stateLock.lock(); _listenFd = newValue; stateLock.unlock() }
    }
    var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
        set { stateLock.lock(); _isRunning = newValue; stateLock.unlock() }
    }
    var acceptGeneration: Int {
        stateLock.lock(); defer { stateLock.unlock() }; return _acceptGeneration
    }
    @discardableResult func bumpAcceptGeneration() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        _acceptGeneration += 1
        return _acceptGeneration
    }
    private var _port: UInt16 = { let v = UserDefaults.standard.integer(forKey: "mcpPort"); return v == 0 ? 3060 : UInt16(v) }()
    var port: UInt16 {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _port }
        set { stateLock.lock(); _port = newValue; stateLock.unlock() }
    }
    var mcpSessions: [String: Date] = [:]
    var mcpLock = NSLock()
    var queue = DispatchQueue(label: "cua.mcp", qos: .userInitiated, attributes: .concurrent)
    // Control-plane calls (lease changes, listing) are serialized. Read-only
    // lease calls (screenshot/AX/zoom) use a per-lease queue, so two windows
    // can be observed concurrently. Every input gesture takes the one global
    // InputGate, matching the single hardware pointer/focus.
    let controlQueue = DispatchQueue(label: "cua.control", qos: .userInitiated)
    let foregroundQueue = DispatchQueue(label: "cua.foreground", qos: .userInitiated)
    private let leaseQueueLock = NSLock()
    private var leaseQueues: [String: DispatchQueue] = [:]
    private let controlTools: Set<String> = ["list_apps", "windows", "acquire", "release",
                                             "foreground_status"]
    private let inputTools: Set<String> = ["click", "type", "key", "scroll", "drag", "hover", "press"]
    let connGate = DispatchSemaphore(value: 8)
    var onStateChange: (() -> Void)?
    private let iconLock = NSLock()
    private var iconCache: [Int32: (String, Date)] = [:]

    private func queueForLease(_ id: String) -> DispatchQueue {
        let key = id.lowercased()
        leaseQueueLock.lock(); defer { leaseQueueLock.unlock() }
        if let q = leaseQueues[key] { return q }
        let q = DispatchQueue(label: "cua.lease.\(key)", qos: .userInitiated)
        leaseQueues[key] = q
        return q
    }

    private func dropLeaseQueue(_ id: String) {
        leaseQueueLock.lock(); leaseQueues.removeValue(forKey: id.lowercased()); leaseQueueLock.unlock()
    }

    func runTool(name: String, args: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if name == "request_foreground" {
            // This call deliberately waits for menubar approval. It runs on its
            // own queue so background sessions can keep working until the user
            // approves and the coordinator revokes them.
            foregroundQueue.sync { result = CuaEngine.shared.dispatch(tool: name, params: args) }
        } else if inputTools.contains(name) {
            InputGate.shared.withLock {
                result = CuaEngine.shared.dispatch(tool: name, params: args)
            }
        } else if controlTools.contains(name) {
            controlQueue.sync { result = CuaEngine.shared.dispatch(tool: name, params: args) }
        } else if let id = args["acquisitionId"] as? String, !id.isEmpty {
            queueForLease(id).sync { result = CuaEngine.shared.dispatch(tool: name, params: args) }
        } else {
            controlQueue.sync { result = CuaEngine.shared.dispatch(tool: name, params: args) }
        }
        if name == "release", let id = args["acquisitionId"] as? String {
            dropLeaseQueue(id)
        }
        return result
    }
    // A peer that connects and then says nothing would otherwise pin a worker forever,
    // so every socket gets read/write deadlines.
    static let ioTimeout = timeval(tv_sec: 10, tv_usec: 0)
    static let maxHeadBytes = 64 * 1024
    static let maxBodyBytes = 8 * 1024 * 1024

    static func allowedHost(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return true }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }
    static func allowedOrigin(_ origin: String?, port: UInt16) -> Bool {
        guard let origin = origin?.lowercased(), !origin.isEmpty else { return true }
        return origin == "http://127.0.0.1:\(port)" || origin == "http://localhost:\(port)"
    }

    private static func makeListener(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { clog("socket failed"); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.bind(fd, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            clog("bind 127.0.0.1:\(port) failed: \(String(cString: strerror(errno)))")
            close(fd); return nil
        }
        guard listen(fd, 128) == 0 else {
            clog("listen failed: \(String(cString: strerror(errno)))")
            close(fd); return nil
        }
        return fd
    }

    func start(port: UInt16) {
        // Bind the new port before retiring the old listener, so a failed port
        // change leaves the working server exactly where it was.
        if port == self.port && listenFd >= 0 {
            UserDefaults.standard.set(Int(port), forKey: "mcpPort")
            return
        }
        guard let fd = Self.makeListener(port: port) else { return }
        let old = listenFd
        listenFd = fd
        self.port = port
        UserDefaults.standard.set(Int(port), forKey: "mcpPort")
        isRunning = true
        clog("listening 127.0.0.1:\(port)")
        onStateChange?()
        if old >= 0 { shutdown(old, SHUT_RDWR); close(old) }
        let acceptQ = DispatchQueue(label: "cua.accept", qos: .userInitiated)
        let gen = bumpAcceptGeneration()
        acceptQ.async { [weak self] in
            while let self = self {
                let lfd = self.listenFd
                if lfd < 0 || self.acceptGeneration != gen { break }
                // Backpressure: past the cap, stop accepting and leave the rest in the kernel
                // backlog rather than queueing fds we cannot service or close.
                self.connGate.wait()
                // Re-check after the wait: a port change can retire this loop while it is
                // parked here, and the fd number may already belong to the new listener.
                if self.acceptGeneration != gen { self.connGate.signal(); break }
                var caddr = sockaddr()
                var clen = socklen_t(MemoryLayout<sockaddr>.size)
                let cfd = withUnsafeMutablePointer(to: &caddr) { ptr in
                    accept(lfd, ptr, &clen)
                }
                guard cfd >= 0 else {
                    self.connGate.signal()
                    if self.listenFd < 0 || self.acceptGeneration != gen { break }
                    if errno != EINTR { usleep(10000) }
                    continue
                }
                // A client that hangs up before we finish replying must not take the app with
                // it: send(2) on such a socket raises SIGPIPE, whose default action is death.
                var nosig: Int32 = 1
                setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                self.queue.async {
                    self.handleFd(cfd)
                    self.connGate.signal()
                }
            }
        }
    }
    func stop() {
        let fd = listenFd
        listenFd = -1
        isRunning = false
        bumpAcceptGeneration()          // retire the loop before the fd number can be reused
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        onStateChange?()
    }
    func handleFd(_ fd: Int32) {
        var tv = Self.ioTimeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let (req, bodyLen) = Self.parseHTTPHead(buf) {
                if bodyLen < 0 {
                    send(fd, status: "400 Bad Request", body: Data("{\"error\":\"bad content-length\"}".utf8))
                    return
                }
                if bodyLen > Self.maxBodyBytes {
                    send(fd, status: "413 Payload Too Large", body: Data("{\"error\":\"body too large\"}".utf8))
                    return
                }
                if Self.isChunked(req) {
                    // Framing lives in the body, so keep reading until the terminator shows up.
                    if buf.count > req.headLen + Self.maxBodyBytes {
                        send(fd, status: "413 Payload Too Large", body: Data("{\"error\":\"body too large\"}".utf8))
                        return
                    }
                    if let body = Self.decodeChunked(buf[buf.startIndex + req.headLen..<buf.endIndex]) {
                        process(req: req, body: body, fd: fd)
                        return
                    }
                } else if buf.count >= req.headLen + bodyLen {
                    let body = buf.subdata(in: buf.startIndex + req.headLen..<buf.startIndex + req.headLen + bodyLen)
                    process(req: req, body: body, fd: fd)
                    return
                }
            } else if buf.count > Self.maxHeadBytes {
                // Nothing resembling a head after 64 KB: stop buffering it forever.
                send(fd, status: "431 Request Header Fields Too Large", body: Data("{\"error\":\"head too large\"}".utf8))
                return
            }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n == 0 { close(fd); return }                 // peer finished sending
            if n < 0 {
                if errno == EINTR { continue }
                // EAGAIN under SO_RCVTIMEO (peer went quiet) or a reset — drop it.
                close(fd)
                return
            }
            buf.append(contentsOf: Array(chunk[0..<n]))
        }
    }
    struct HTTPReq {
        var method: String
        var path: String
        var headers: [String: String]
        var headLen: Int
    }
    static func parseHTTPHead(_ data: Data) -> (HTTPReq, Int)? {
        // Find the blank line in raw bytes. Decoding the whole buffer as UTF-8 first meant
        // any non-text prefix (a TLS ClientHello against http://, an h2 preface, garbage)
        // never parsed, so the reader sat there until the peer gave up.
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)) else { return nil }
        let headData = data[data.startIndex..<sep.upperBound]
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { headers[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        var len = 0
        if let rawLen = headers["content-length"] {
            guard let parsed = Int(rawLen), parsed >= 0 else {
                let req = HTTPReq(method: String(parts[0]), path: String(parts[1]), headers: headers, headLen: headData.count)
                return (req, -1)
            }
            len = parsed
        }
        // Byte count, not String count: headLen indexes into the raw buffer.
        let headLen = headData.count
        return (HTTPReq(method: String(parts[0]), path: String(parts[1]), headers: headers, headLen: headLen), len)
    }
    static func isChunked(_ req: HTTPReq) -> Bool {
        (req.headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
    }
    /// Decodes a `Transfer-Encoding: chunked` body. Returns nil while the terminating
    /// chunk is still missing, so the caller keeps reading.
    static func decodeChunked(_ data: Data) -> Data? {
        var out = Data()
        var i = data.startIndex
        while true {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: i..<data.endIndex) else { return nil }
            let line = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
            let token = line.split(separator: ";")[0].trimmingCharacters(in: .whitespaces)
            guard let size = Int(token, radix: 16), size >= 0, size <= Self.maxBodyBytes else { return nil }
            if size == 0 { return out }                     // last chunk (trailers ignored)
            let start = lineEnd.upperBound
            guard size <= data.endIndex - start, data.endIndex - start - size >= 2 else { return nil }
            out.append(data[start..<start + size])
            i = start + size + 2
        }
    }
    func iconBase64Cached(pid: Int32) -> String {
        iconLock.lock()
        if let cached = iconCache[pid], Date().timeIntervalSince(cached.1) < 60 {
            iconLock.unlock()
            return cached.0
        }
        iconLock.unlock()
        let value = Self.iconBase64(pid: pid)
        iconLock.lock()
        iconCache = iconCache.filter { Date().timeIntervalSince($0.value.1) < 60 }
        iconCache[pid] = (value, Date())
        iconLock.unlock()
        return value
    }

    static func iconBase64(pid: Int32) -> String {        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
              let icon = app.icon else { return "" }
        let size = 40
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let r = rep else { return "" }
        r.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: r) else { NSGraphicsContext.restoreGraphicsState(); return "" }
        NSGraphicsContext.current = ctx
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return r.representation(using: .png, properties: [:])?.base64EncodedString() ?? ""
    }
    func process(req: HTTPReq, body: Data, fd: Int32) {
        let pathOnly = String(req.path.split(separator: "?")[0])
        let host = req.headers["host"]
        let origin = req.headers["origin"]
        if !Self.allowedHost(host, port: port) {
            send(fd, status: "403 Forbidden", body: Data("{\"error\":\"invalid host\"}".utf8))
            return
        }
        if let origin = origin, !Self.allowedOrigin(origin, port: port) {
            send(fd, status: "403 Forbidden", body: Data("{\"error\":\"invalid origin\"}".utf8))
            return
        }
        let isJSON = (req.headers["content-type"] ?? "").lowercased().contains("application/json")
        // --- Web UI + APIs for the transparent WebView popover (native glass behind) ---
        if pathOnly == "/" || pathOnly == "/index.html" {
            guard req.method == "GET" else { send(fd, status: "405 Method Not Allowed", body: Data(), extraHeaders: [:]); return }
            send(fd, status: "200 OK", body: webUIHTML.data(using: .utf8)!, extraHeaders: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"])
            return
        }
        if pathOnly == "/api/state" && req.method == "GET" {
            let sessions = SessionStore.shared.sessions().map { s -> [String: Any] in
                var d: [String: Any] = ["pid": Int(s.pid), "app": s.appName, "agent": s.agent ?? "unknown",
                                         "id": s.id, "acquisitionId": s.id, "scope": s.scope.rawValue,
                                         "coordSpace": s.coordSpace.rawValue, "icon": iconBase64Cached(pid: s.pid)]
                if let wid = s.wid { d["wid"] = Int(wid) }
                if let title = s.windowTitle { d["windowTitle"] = title }
                return d
            }
            let ax = AXIsProcessTrusted(); let scr = CGPreflightScreenCaptureAccess()
            let missing = [ax ? nil : "Accessibility", scr ? nil : "Screen Recording"].compactMap { $0 }.joined(separator: " + ")
            let perms = (ax && scr) ? "Permissions OK (Accessibility + Screen Recording)." : "Missing: \(missing). Grant as Cua.app via the button below."
            let payload: [String: Any] = ["port": Int(port), "url": "http://127.0.0.1:\(port)/mcp", "perms": perms,
                                          "ax": ax, "scr": scr, "sessions": sessions,
                                          "appIcon": iconBase64Cached(pid: getpid()),
                                          "appPath": Bundle.main.bundleURL.path,
                                          "foreground": ForegroundCoordinator.shared.status()]
            send(fd, status: "200 OK", body: jsonData(payload), extraHeaders: ["Cache-Control": "no-store"])
            return
        }
        if pathOnly == "/api/free" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if let pid = (obj["pid"] as? Int) ?? (obj["pid"] as? Double).flatMap({ Int(exactly: $0) }) {
                let wid = (obj["wid"] as? Int) ?? (obj["wid"] as? Double).flatMap({ Int(exactly: $0) })
                let p32 = Int32(clamping: pid)
                let w32 = wid.flatMap { $0 > 0 && $0 <= Int(UInt32.max) ? UInt32($0) : nil }
                controlQueue.sync {
                    let victims = SessionStore.shared.sessions().filter {
                        $0.pid == p32 && (w32 == nil || $0.wid == w32)
                    }
                    let hadForeground = victims.contains { $0.scope == .foreground }
                    SessionStore.shared.free(pid: p32, wid: w32)
                    for s in victims {
                        SnapshotStore.shared.remove(sessionID: s.id)
                        AXIndexStore.shared.remove(sessionID: s.id)
                        self.dropLeaseQueue(s.id)
                    }
                    if hadForeground { ForegroundCoordinator.shared.stop() }
                }
                onStateChange?()
            }
            send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        if pathOnly == "/api/foreground" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            guard req.headers["x-cua-ui-token"] == uiToken else {
                send(fd, status: "403 Forbidden", body: Data("{\"error\":\"foreground approval must come from the Cua menubar\"}".utf8))
                return
            }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let action = (obj["action"] as? String ?? "").lowercased()
            let requestId = (obj["requestId"] as? String) ?? ""
            var ok = false
            switch action {
            case "approve":
                ok = ForegroundCoordinator.shared.approve(requestId: requestId) == nil
            case "deny":
                ok = ForegroundCoordinator.shared.deny(requestId: requestId)
            case "stop":
                let sid = ForegroundCoordinator.shared.activeSessionID
                ForegroundCoordinator.shared.stop()
                if let sid { dropLeaseQueue(sid) }
                ok = true
            default:
                break
            }
            let payload: [String: Any] = ["ok": ok, "foreground": ForegroundCoordinator.shared.status()]
            send(fd, status: ok ? "200 OK" : "409 Conflict", body: jsonData(payload), extraHeaders: [:])
            return
        }
        if pathOnly == "/api/port" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if let np = (obj["port"] as? Int) ?? (obj["port"] as? Double).flatMap({ Int(exactly: $0) }), np >= 1024 && np <= 65535 {
                DispatchQueue.main.sync { [weak self] in self?.start(port: UInt16(np)) }
                let ok = port == UInt16(np) && isRunning
                if ok {
                    send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
                } else {
                    send(fd, status: "409 Conflict", body: "{\"ok\":false,\"error\":\"port bind failed\"}".data(using: .utf8)!, extraHeaders: [:])
                }
            } else {
                send(fd, status: "400 Bad Request", body: "{\"error\":\"bad port\"}".data(using: .utf8)!, extraHeaders: [:])
            }
            return
        }
        if pathOnly == "/api/grant" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            DispatchQueue.main.async {
                if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
                if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            }
            send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        if pathOnly == "/api/open-settings" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            DispatchQueue.main.async {
                for s in ["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                          "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"] {
                    if let u = URL(string: s) { NSWorkspace.shared.open(u) }
                }
            }
            send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        if pathOnly == "/api/quit" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
            ForegroundCoordinator.shared.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApplication.shared.terminate(nil) }
            return
        }
        // Only /mcp is implemented; 404 otherwise
        guard pathOnly == "/mcp" else {
            send(fd, status: "404 Not Found", body: "{\"error\":\"not found\"}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        if req.method == "GET" || req.method == "DELETE" {
            send(fd, status: "405 Method Not Allowed", body: Data(), extraHeaders: ["Allow": "POST"])
            return
        }
        guard req.method == "POST" else {
            send(fd, status: "405 Method Not Allowed", body: "{\"error\":\"method\"}".data(using: .utf8)!, extraHeaders: ["Allow": "POST"])
            return
        }
        guard isJSON else {
            send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8))
            return
        }
        guard !body.isEmpty else {
            send(fd, status: "400 Bad Request", body: "{\"error\":\"empty body\"}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            send(fd, status: "400 Bad Request", body: "{\"error\":\"bad json\"}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        let method = obj["method"] as? String ?? ""
        let id = obj["id"]
        let params = (obj["params"] as? [String: Any]) ?? [:]
        // notifications have no id -> no reply (except batch)
        if id == nil, method.hasPrefix("notifications/") {
            send(fd, status: "202 Accepted", body: Data(), extraHeaders: [:], close: true)
            return
        }
        let (result, sessionId) = handleRPC(method: method, params: params, headers: req.headers)
        // build JSON-RPC response
        var resp: [String: Any] = ["jsonrpc": "2.0"]
        if let id = id { resp["id"] = id } else { resp["id"] = NSNull() }
        if let result = result {
            resp["result"] = result
        } else {
            resp["error"] = ["code": -32601, "message": "method not found \(method)"]
        }
        var headers: [String: String] = [:]
        if let sessionId = sessionId { headers["Mcp-Session-Id"] = sessionId }
        // Single JSON response (valid for Streamable HTTP without SSE)
        let data = jsonData(resp)
        send(fd, status: "200 OK", body: data, extraHeaders: headers)
    }
    func handleRPC(method: String, params: [String: Any], headers: [String: String]) -> ([String: Any]?, String?) {
        // Return session id for initialize; otherwise echo provided one (stateless tolerance)
        let incomingSession = headers["mcp-session-id"] ?? headers["mcp-session-id".lowercased()]
        switch method {
        case "initialize":
            let sid = UUID().uuidString
            mcpLock.lock(); mcpSessions[sid] = Date(); mcpLock.unlock()
            let result: [String: Any] = [
                "protocolVersion": "2025-06-18",
                "serverInfo": ["name": "cua-mcp", "version": "1.1"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": "Cua controls apps through leases. Workflow: list_apps -> acquire (scope app or window) -> windows/screenshot -> act -> release. Coordinates use the lease coordSpace (norm1000 by default): norm1000 is 0..1000 relative to the target window screenshot; image is pixels in the last screenshot/zoom; screen is absolute points for app and foreground leases. Call screenshot before image-mode actions. Use zoom for small UI, hover to trigger hover states. Background leases post events to the app process and never move the user's pointer; foreground grants use the real HID path. request_foreground grants full-Mac control; background and foreground leases are mutually exclusive. If LEASE_HELD or GLOBAL_FOREGROUND_ACTIVE, stop or ask the user; do not retry in a loop."
            ]
            var r = result
            // Advertise only a protocol version this server actually speaks.
            if let pv = params["protocolVersion"] as? String, ["2024-11-05", "2025-03-26", "2025-06-18"].contains(pv) {
                r["protocolVersion"] = pv
            }
            return (r, sid)
        case "notifications/initialized":
            return ([:], incomingSession)
        case "ping":
            return ([:], incomingSession)
        case "tools/list":
            return (["tools": toolDefs()], incomingSession)
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            // Blocking, UI-facing work (captures, usleep-paced input) must not block the socket
            // queue: the menubar UI polls /api/state while an agent call runs.
            let result = runTool(name: name, args: args)
            return (result, incomingSession)
        case "resources/list":
            return (["resources": []], incomingSession)
        case "prompts/list":
            return (["prompts": []], incomingSession)
        default:
            return (nil, incomingSession)
        }
    }
    func send(_ fd: Int32, status: String, body: Data, extraHeaders: [String: String] = [:], close: Bool = true) {
        var h = "HTTP/1.1 \(status)\r\n"
        h += "Content-Type: \(extraHeaders["Content-Type"] ?? "application/json")\r\n"
        h += "Content-Length: \(body.count)\r\n"
        h += "Connection: close\r\n"
        h += "X-Content-Type-Options: nosniff\r\n"
        h += "X-Frame-Options: DENY\r\n"
        h += "Referrer-Policy: no-referrer\r\n"
        h += "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'\r\n"
        h += "Cache-Control: no-store\r\n"
        for (k, v) in extraHeaders where k.lowercased() != "content-type" { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var out = h.data(using: .utf8)!
        out.append(body)
        let bytes = [UInt8](out)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { ptr in
                Darwin.send(fd, ptr.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            break
        }
        if close { Darwin.close(fd) }
    }
}

