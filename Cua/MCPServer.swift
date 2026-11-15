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
    var content: [[String: Any]] = [
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
    let widProp: [String: Any] = ["type": "number", "description": "Window id (default: main window of pid)"]
    let bgProp: [String: Any] = ["type": "boolean", "description": "Background delivery (default true). False posts to HID tap — avoid while user works."]
    let focusProp: [String: Any] = ["type": "boolean", "description": "Briefly take key focus via focus-without-raise, then restore exact window (default false)"]
    return [
        ["name": "list_apps", "description": "List running apps and which are held by Cua sessions", "inputSchema": obj([:], required: [])],
        ["name": "windows", "description": "List windows (optionally for one pid/app)", "inputSchema": obj(["pid": pidProp, "app": appProp, "all": ["type": "boolean"]], required: [])],
        ["name": "acquire", "description": "Acquire an app lease. Returns acquisitionId to use on every later call. Fails with LEASE_HELD if held — ask the user to free it in the Cua menubar UI.", "inputSchema": obj(["pid": pidProp, "app": appProp, "agentLabel": ["type": "string"]], required: [])],
        ["name": "release", "description": "Release an app lease (normal exit).", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp], required: ["acquisitionId"])],
        ["name": "screenshot", "description": "Capture a window as inline image (ImageContent, in-memory). Optional grid/cursor overlay.", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "wid": widProp, "grid": ["type": "number"], "cursor": ["type": "string", "description": "x,y or last"], "clean": ["type": "boolean"]], required: ["acquisitionId"])],
        ["name": "move", "description": "Remember a cursor position and return a screenshot with the crosshair overlay. In-memory — no files.", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "wid": widProp, "toX": ["type": "number"], "toY": ["type": "number"], "byX": ["type": "number"], "byY": ["type": "number"], "grid": ["type": "number"]], required: ["acquisitionId"])],
        ["name": "click", "description": "Background click routed to window (no focus change by default).", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "double": ["type": "boolean"], "right": ["type": "boolean"], "bg": bgProp, "focus": focusProp], required: ["acquisitionId"])],
        ["name": "type", "description": "Type unicode text (keycode 0 + unicode; games need key).", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "wid": widProp, "text": ["type": "string"], "bg": bgProp, "focus": focusProp], required: ["acquisitionId", "text"])],
        ["name": "key", "description": "Virtual keycode (+modifiers, optional unicode char, hold ms).", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "wid": widProp, "code": ["type": "number"], "shift": ["type": "boolean"], "ctrl": ["type": "boolean"], "alt": ["type": "boolean"], "cmd": ["type": "boolean"], "fn": ["type": "boolean"], "char": ["type": "string"], "holdMs": ["type": "number"], "bg": bgProp, "focus": focusProp], required: ["acquisitionId", "code"])],
        ["name": "scroll", "description": "Pixel scroll at a point.", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "dx": ["type": "number"], "dy": ["type": "number"], "bg": bgProp, "focus": focusProp], required: ["acquisitionId"])],
        ["name": "drag", "description": "Drag from one point to another (12 steps).", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "wid": widProp, "fromX": ["type": "number"], "fromY": ["type": "number"], "toX": ["type": "number"], "toY": ["type": "number"], "from": ["type": "string"], "to": ["type": "string"], "bg": bgProp, "focus": focusProp], required: ["acquisitionId"])],
        ["name": "ax", "description": "Accessibility tree dump (positional index; same walk as press).", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "depth": ["type": "number"], "maxNodes": ["type": "number"]], required: ["acquisitionId"])],
        ["name": "press", "description": "AXPress by positional index (guard with expectRole/expectTitle).", "inputSchema": obj(["pid": pidProp, "app": appProp, "acquisitionId": idProp, "index": ["type": "number"], "depth": ["type": "number"], "maxNodes": ["type": "number"], "expectRole": ["type": "string"], "expectTitle": ["type": "string"]], required: ["acquisitionId", "index"])],
    ]
}

func leaseHeldResult(_ s: Session) -> [String: Any] {
    let payload: [String: Any] = [
        "code": "LEASE_HELD",
        "pid": s.pid,
        "app": s.appName,
        "holder": s.agentLabel ?? "unknown",
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
    var listenFd: Int32 = -1
    var port: UInt16 = { let v = UserDefaults.standard.integer(forKey: "mcpPort"); return v == 0 ? 3060 : UInt16(v) }()
    var mcpSessions: [String: Date] = [:]
    var mcpLock = NSLock()
    var queue = DispatchQueue(label: "cua.mcp", qos: .userInitiated)
    var onStateChange: (() -> Void)?
    var isRunning = false
    // A peer that connects and then says nothing would otherwise pin a worker forever,
    // so every socket gets read/write deadlines.
    static let ioTimeout = timeval(tv_sec: 10, tv_usec: 0)
    static let maxHeadBytes = 64 * 1024
    static let maxBodyBytes = 8 * 1024 * 1024

    func start(port: UInt16) {
        // Same port already listening: keep the socket (a cancel+rebind on the same
        // port races the close and fails with "Address already in use").
        if port == self.port && listenFd >= 0 {
            UserDefaults.standard.set(Int(port), forKey: "mcpPort")
            return
        }
        self.port = port
        UserDefaults.standard.set(Int(port), forKey: "mcpPort")
        stop()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { clog("socket failed"); return }
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
        guard ok == 0 else { clog("bind 127.0.0.1:\(port) failed: \(String(cString: strerror(errno)))"); close(fd); return }
        guard listen(fd, 128) == 0 else { clog("listen failed: \(String(cString: strerror(errno)))"); close(fd); return }
        listenFd = fd
        isRunning = true
        clog("listening 127.0.0.1:\(port)")
        onStateChange?()
        let acceptQ = DispatchQueue(label: "cua.accept", qos: .userInitiated)
        acceptQ.async { [weak self] in
            while let self = self, self.listenFd >= 0 {
                var caddr = sockaddr()
                var clen = socklen_t(MemoryLayout<sockaddr>.size)
                let cfd = withUnsafeMutablePointer(to: &caddr) { ptr in
                    accept(self.listenFd, ptr, &clen)
                }
                guard cfd >= 0 else { if self.listenFd < 0 { break }; if errno != EINTR { usleep(10000) }; continue }
                // A client that hangs up before we finish replying must not take the app with
                // it: send(2) on such a socket raises SIGPIPE, whose default action is death.
                var nosig: Int32 = 1
                setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                self.queue.async { self.handleFd(cfd) }
            }
        }
    }
    func stop() {
        let fd = listenFd
        listenFd = -1
        isRunning = false
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
                if bodyLen > Self.maxBodyBytes {
                    send(fd, status: "413 Payload Too Large", body: Data("{\"error\":\"body too large\"}".utf8))
                    return
                }
                if buf.count >= req.headLen + bodyLen {
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
        let len = Int(headers["content-length"] ?? "0") ?? 0
        // Byte count, not String count: headLen indexes into the raw buffer.
        let headLen = headData.count
        return (HTTPReq(method: String(parts[0]), path: String(parts[1]), headers: headers, headLen: headLen), len)
    }
    static func iconBase64(pid: Int32) -> String {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
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
        // --- Web UI + APIs for the transparent WebView popover (native glass behind) ---
        if pathOnly == "/" || pathOnly == "/index.html" {
            guard req.method == "GET" else { send(fd, status: "405 Method Not Allowed", body: Data(), extraHeaders: [:]); return }
            send(fd, status: "200 OK", body: webUIHTML.data(using: .utf8)!, extraHeaders: ["Content-Type": "text/html; charset=utf-8"])
            return
        }
        if pathOnly == "/api/state" && req.method == "GET" {
            let sessions = SessionStore.shared.sessions().map { s -> [String: Any] in
                ["pid": Int(s.pid), "app": s.appName, "agent": s.agentLabel ?? "unknown", "id": s.id, "acquisitionId": s.id, "icon": Self.iconBase64(pid: s.pid)]
            }
            let ax = AXIsProcessTrusted(); let scr = CGPreflightScreenCaptureAccess()
            let missing = [ax ? nil : "Accessibility", scr ? nil : "Screen Recording"].compactMap { $0 }.joined(separator: " + ")
            let perms = (ax && scr) ? "Permissions OK (Accessibility + Screen Recording)." : "Missing: \(missing). Grant as Cua.app via the button below."
            let payload: [String: Any] = ["port": Int(port), "url": "http://127.0.0.1:\(port)/mcp", "perms": perms, "ax": ax, "scr": scr, "sessions": sessions]
            send(fd, status: "200 OK", body: jsonData(payload), extraHeaders: [:])
            return
        }
        if pathOnly == "/api/free" && req.method == "POST" {
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if let pid = (obj["pid"] as? Int) ?? (obj["pid"] as? Double).map({ Int($0) }) {
                SessionStore.shared.free(pid: Int32(pid))
                onStateChange?()
            }
            send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        if pathOnly == "/api/port" && req.method == "POST" {
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if let np = (obj["port"] as? Int) ?? (obj["port"] as? Double).map({ Int($0) }), np >= 1024 && np <= 65535 {
                DispatchQueue.main.async { [weak self] in self?.start(port: UInt16(np)) }
                send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
            } else {
                send(fd, status: "400 Bad Request", body: "{\"error\":\"bad port\"}".data(using: .utf8)!, extraHeaders: [:])
            }
            return
        }
        if pathOnly == "/api/grant" && req.method == "POST" {
            DispatchQueue.main.async {
                if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
                if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            }
            send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        if pathOnly == "/api/open-settings" && req.method == "POST" {
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
            send(fd, status: "200 OK", body: "{\"ok\":true}".data(using: .utf8)!, extraHeaders: [:])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApplication.shared.terminate(nil) }
            return
        }
        // Only /mcp is implemented; 404 otherwise
        guard pathOnly == "/mcp" else {
            send(fd, status: "404 Not Found", body: "{\"error\":\"not found\"}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        if req.method == "GET" {
            send(fd, status: "200 OK", body: "{\"ok\":true,\"server\":\"cua-mcp\"}".data(using: .utf8)!, extraHeaders: [:])
            return
        }
        if req.method == "DELETE" {
            // Client closing a session: nothing to reply, but the fd is ours to close.
            close(fd)
            return
        }
        guard req.method == "POST" else {
            send(fd, status: "405 Method Not Allowed", body: "{\"error\":\"method\"}".data(using: .utf8)!, extraHeaders: [:])
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
                "serverInfo": ["name": "cua-mcp", "version": "1.0"],
                "capabilities": ["tools": ["listChanged": false]]
            ]
            // Enforce protocolVersion from client if present
            var r = result
            if let pv = params["protocolVersion"] as? String { r["protocolVersion"] = pv }
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
            // Dispatch on background queue is risky for UI-facing focus code (needs RunLoop? No, all
            // blocking calls use usleep + SkyLight, safe off-main). Run synchronously here.
            let result = CuaEngine.shared.dispatch(tool: name, params: args)
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

