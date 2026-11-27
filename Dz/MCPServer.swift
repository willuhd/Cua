import Cocoa
import Darwin

// MARK: - MCP helpers (JSON-RPC over HTTP)
/// The version an MCP client sees is the app version. There is no second
/// number to keep in sync with Info.plist.
let dzVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
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
    return r
}
/// Read by the agent before it touches anything. Written for that agent, not
/// as a description of the source: what to do, in what order, and when to stop.
let dzInstructions = [
    "dz lets you use someone's Mac for them: their pointer, their menus, their windows.",
    "",
    "Start with list_apps, then acquire the app you need. You get an acquisitionId; pass it on every call until you release. By default you work in the background: your clicks and keys reach that app without moving their pointer or raising the window.",
    "",
    "Screenshot before you click. Coordinates default to 0..1000 across the window, so 500,500 is the middle. Use zoom when the target is small, and hover when a tooltip or menu only opens on hover.",
    "",
    "If the work genuinely needs their whole screen and real keyboard, call request_foreground. They approve in the menubar, and from then on everything is real: the pointer moves, keys go to whatever is in front. Screenshot first, and again after they touch anything.",
    "",
    "When you are done, release. If a call answers LEASE_HELD or GLOBAL_FOREGROUND_ACTIVE, someone else has it: stop and ask, do not retry in a loop."
].joined(separator: "\n")

// MARK: - MCP tool definitions (served by tools/list)
func toolDefs() -> [[String: Any]] {
    func obj(_ props: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    let pidProp: [String: Any] = ["type": "number", "description": "The app's process id from list_apps"]
    let appProp: [String: Any] = ["type": "string", "description": "App name or bundle id, if you would rather not pass a pid"]
    let idProp: [String: Any] = ["type": "string", "description": "The acquisitionId acquire gave you (or the token shown for the app in the menubar). Required on every call until you release."]
    let widProp: [String: Any] = ["type": "number", "description": "Which window to act on, from windows. App leases use the main window unless you pass one; a window lease is fixed to its wid."]
    let coordProp: [String: Any] = ["type": "string", "enum": ["image", "norm1000", "screen"],
                                   "description": "How to read x,y. norm1000 (the default) is 0..1000 across the window. image is pixels in your last screenshot or zoom. screen is absolute display points, and only for app and foreground leases."]
    let regionProp: [String: Any] = ["type": "object", "description": "Crop of the window to return, as {x,y,width,height} fractions of the window. Defaults to all of it."]
    return [
        ["name": "list_apps", "description": "Every app you could use, which ones are already held and by whom, and whether someone has full control of the Mac right now. Start here.", "inputSchema": obj([:], required: [])],
        ["name": "windows", "description": "The windows of one app (or all apps), so you can pick one to target.", "inputSchema": obj(["pid": pidProp, "app": appProp, "all": ["type": "boolean"]], required: [])],
        ["name": "acquire", "description": "Claim an app, or one window of it, before acting. Returns the acquisitionId you pass on every later call. Another agent holding it means LEASE_HELD: ask the user to stop it, do not wait.", "inputSchema": obj(["pid": pidProp, "app": appProp, "scope": ["type": "string", "enum": ["app", "window"], "description": "app (default) or window"], "wid": widProp, "coordSpace": coordProp, "agent": ["type": "string"]], required: [])],
        ["name": "release", "description": "Give the app back. Do this when you are finished, or when another agent needs it.", "inputSchema": obj(["acquisitionId": idProp], required: ["acquisitionId"])],
        ["name": "screenshot", "description": "See the app. Returns a PNG plus the geometry you need for coordinates. Take one before you click, and again after the user touches anything.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "region": regionProp, "maxDimension": ["type": "number", "description": "Longest edge in pixels. Default 2560; the full-resolution capture stays cached for zoom."], "grid": ["type": "number"], "cursor": ["type": "string", "description": "x,y in the lease coordinate space, or last"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "zoom", "description": "Look closer at part of the window when the target is too small to aim at in a full screenshot. Crops the last full-resolution capture, so it never blurs.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "part": ["type": "string", "enum": ["top-left", "top-right", "bottom-left", "bottom-right", "center", "cursor"]], "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "size": ["type": "number", "description": "How much of the window to return, 0.1..1.0. Default 0.5, or 0.25 for the cursor."], "maxDimension": ["type": "number", "description": "Longest edge in pixels. Default 2560."], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "move", "description": "Move your own cursor marker without touching the real mouse, and see where it landed. Use it to check a target before clicking.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "grid": ["type": "number"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "hover", "description": "Rest the pointer on something so hover states, tooltips and menus open, then look at the result.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "grid": ["type": "number"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "click", "description": "Click a point in the target. Background work goes to the app without moving the user's pointer; with a foreground grant it is a real click.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "double": ["type": "boolean"], "right": ["type": "boolean"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "type", "description": "Type text into whatever has focus in the target app. Up to 4096 characters per call.", "inputSchema": obj(["acquisitionId": idProp, "text": ["type": "string", "description": "The text to type. Up to 4096 characters per call; split longer text."]], required: ["acquisitionId", "text"])],
        ["name": "key", "description": "Press one key, with modifiers, for things typing cannot do: shortcuts, arrows, enter, escape.", "inputSchema": obj(["acquisitionId": idProp, "code": ["type": "number"], "shift": ["type": "boolean"], "ctrl": ["type": "boolean"], "alt": ["type": "boolean"], "cmd": ["type": "boolean"], "fn": ["type": "boolean"], "char": ["type": "string"], "holdMs": ["type": "number"]], required: ["acquisitionId", "code"])],
        ["name": "scroll", "description": "Scroll the target at a point. Positive dy scrolls the content up.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "x": ["type": "number"], "y": ["type": "number"], "at": ["type": "string"], "dx": ["type": "number"], "dy": ["type": "number"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "drag", "description": "Press, move and release, for sliders, selections and drag-and-drop.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "fromX": ["type": "number"], "fromY": ["type": "number"], "toX": ["type": "number"], "toY": ["type": "number"], "from": ["type": "string"], "to": ["type": "string"], "steps": ["type": "number"], "stepMs": ["type": "number"], "startHoldMs": ["type": "number"], "endHoldMs": ["type": "number"], "coordSpace": coordProp], required: ["acquisitionId"])],
        ["name": "ax", "description": "Read the app's accessibility tree to find exact controls, labels and buttons, with positions, without a screenshot.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "depth": ["type": "number"], "maxNodes": ["type": "number"]], required: ["acquisitionId"])],
        ["name": "press", "description": "Activate a control found with ax, by its index. Safer than clicking a guess; guard it with expectRole/expectTitle so a stale tree cannot press the wrong thing.", "inputSchema": obj(["acquisitionId": idProp, "wid": widProp, "index": ["type": "number"], "depth": ["type": "number"], "maxNodes": ["type": "number"], "expectRole": ["type": "string"], "expectTitle": ["type": "string"]], required: ["acquisitionId", "index"])],
        ["name": "request_foreground", "description": "Ask the user for the real pointer and keyboard, when the job truly needs the whole screen. Waits for them to approve in the menubar; on approval every background lease is dropped. Do not call this for work you can do in the background.", "inputSchema": obj(["reason": ["type": "string"], "coordSpace": coordProp, "agent": ["type": "string"]], required: [])],
        ["name": "terminal", "description": "Run a command on this Mac and return its output. Use it for anything that is easier to do in a shell than through the UI. Blocks up to the timeout; pass a longer one for slow work.", "inputSchema": obj(["command": ["type": "string", "description": "The command line, run through zsh -lc"], "cwd": ["type": "string", "description": "Working directory, if it matters"], "timeoutSeconds": ["type": "number", "description": "Wall clock limit, default 30, max 600"]], required: ["command"])],
        ["name": "files", "description": "Work with files in the folder this Mac shares: list, read, write, mkdir, delete, stat. Paths are relative to the shared folder and cannot leave it.", "inputSchema": obj(["op": ["type": "string", "enum": ["list", "read", "write", "mkdir", "delete", "stat"], "description": "What to do"], "path": ["type": "string", "description": "Path relative to the shared folder"], "text": ["type": "string", "description": "Contents, for write"]], required: ["op", "path"])],
        ["name": "mount", "description": "Mount the other Mac's shared folder as a volume, so its files appear in the Finder like a disk. Returns where it mounted.", "inputSchema": obj(["host": ["type": "string", "description": "Address of the other Mac"], "port": ["type": "number", "description": "Its share port, default 47101"], "name": ["type": "string", "description": "Volume name, default dz"], "path": ["type": "string", "description": "Where to mount, default /Volumes/<name>"]], required: ["host"])],
        ["name": "foreground_status", "description": "Whether the user has given you (or anyone) full control, or a request is still waiting.", "inputSchema": obj([:], required: [])],
    ]
}

func leaseHeldResult(_ s: Session) -> [String: Any] {
    let payload: [String: Any] = [
        "code": "LEASE_HELD",
        "pid": s.pid,
        "app": s.appName,
        "holder": s.agent ?? "unknown",
        "hint": "This app is held by another agent. Ask the user to free this app's lease in the dz menubar UI, then acquire again."
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
    /// Set when the user shares this Mac's MCP endpoint beyond loopback.
    static var bindAll = false
    /// Required on every /mcp call while the endpoint is shared. Generated once
    /// and kept, because a token that changes on launch is not a token.
    /// Whether the endpoint is shared beyond this machine.
    static var expose: Bool {
        get { UserDefaults.standard.bool(forKey: "dz.mcp.expose") }
        set { UserDefaults.standard.set(newValue, forKey: "dz.mcp.expose") }
    }

    /// First non-loopback IPv4 on a tunnel interface, which on this setup is
    /// the tailnet address. Nil when the tailnet is down.
    static func sharedAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var result: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var raw = addr.pointee
            withUnsafePointer(to: &raw) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var address = sin.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
            }
            let text = String(cString: buffer)
            if text.hasPrefix("100.") { result = text; break }
        }
        return result
    }

    /// The folder this Mac offers to the other one, if the user turned it on.
    static var shareFolder: String? {
        get { UserDefaults.standard.string(forKey: "dz.share.folder") }
        set { UserDefaults.standard.set(newValue, forKey: "dz.share.folder") }
    }

    static var remoteToken: String = {
        let key = "dz.mcp.token"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
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
    var queue = DispatchQueue(label: "dz.mcp", qos: .userInitiated, attributes: .concurrent)
    // Control-plane calls (lease changes, listing) are serialized. Read-only
    // lease calls (screenshot/AX/zoom) use a per-lease queue, so two windows
    // can be observed concurrently. Every input gesture takes the one global
    // InputGate, matching the single hardware pointer/focus.
    let controlQueue = DispatchQueue(label: "dz.control", qos: .userInitiated)
    let foregroundQueue = DispatchQueue(label: "dz.foreground", qos: .userInitiated)
    private let leaseQueueLock = NSLock()
    private var leaseQueues: [String: DispatchQueue] = [:]
    private let controlTools: Set<String> = ["list_apps", "windows", "acquire", "release",
                                             "foreground_status", "terminal", "mount", "files"]
    private let inputTools: Set<String> = ["click", "type", "key", "scroll", "drag", "hover"]
    let connGate = DispatchSemaphore(value: 8)
    var onStateChange: (() -> Void)?
    private let iconLock = NSLock()
    private var iconCache: [Int32: (String, Date)] = [:]

    private func queueForLease(_ id: String) -> DispatchQueue {
        let key = id.lowercased()
        leaseQueueLock.lock(); defer { leaseQueueLock.unlock() }
        if let q = leaseQueues[key] { return q }
        let q = DispatchQueue(label: "dz.lease.\(key)", qos: .userInitiated)
        leaseQueues[key] = q
        return q
    }

    private func dropLeaseQueue(_ id: String) {
        leaseQueueLock.lock(); leaseQueues.removeValue(forKey: id.lowercased()); leaseQueueLock.unlock()
    }

    private func dropAllLeaseQueues() {
        leaseQueueLock.lock(); leaseQueues.removeAll(); leaseQueueLock.unlock()
    }

    func runTool(name: String, args: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if name == "request_foreground" {
            // This call deliberately waits for menubar approval. It runs on its
            // own queue so background sessions can keep working until the user
            // approves and the coordinator revokes them.
            foregroundQueue.sync { result = DzEngine.shared.dispatch(tool: name, params: args) }
        } else if inputTools.contains(name) {
            if let id = args["acquisitionId"] as? String, !id.isEmpty {
                queueForLease(id).sync {
                    InputGate.shared.withLock {
                        result = DzEngine.shared.dispatch(tool: name, params: args)
                    }
                }
            } else {
                InputGate.shared.withLock {
                    result = DzEngine.shared.dispatch(tool: name, params: args)
                }
            }
        } else if controlTools.contains(name) {
            controlQueue.sync { result = DzEngine.shared.dispatch(tool: name, params: args) }
        } else if let id = args["acquisitionId"] as? String, !id.isEmpty {
            queueForLease(id).sync { result = DzEngine.shared.dispatch(tool: name, params: args) }
        } else {
            controlQueue.sync { result = DzEngine.shared.dispatch(tool: name, params: args) }
        }
        if name == "release", let id = args["acquisitionId"] as? String {
            dropLeaseQueue(id)
        }
        if name == "acquire" || name == "release" {
            onStateChange?()
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
        // Loopback unless the user has explicitly shared this Mac's endpoint
        // over the tailnet, which also requires the bearer token below.
        addr.sin_addr.s_addr = MCPServer.bindAll ? INADDR_ANY : inet_addr("127.0.0.1")
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
        let acceptQ = DispatchQueue(label: "dz.accept", qos: .userInitiated)
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
        let host = req.headers["host"]
        let origin = req.headers["origin"]
        // A shared endpoint answers only to the bearer token. Tailscale
        // authenticates devices, not people, so a stolen device would
        // otherwise drive this Mac.
        if Self.bindAll, pathOnly == "/mcp" {
            let presented = req.headers["authorization"] ?? ""
            let expected = "Bearer " + Self.remoteToken
            if presented != expected {
                send(fd, status: "401 Unauthorized", body: Data("{\"error\":\"bearer token required\"}".utf8), extraHeaders: [:])
                return
            }
        }
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
            let sessions = SessionStore.shared.sessions().filter { $0.scope != .foreground }.map { s -> [String: Any] in
                var d: [String: Any] = ["pid": Int(s.pid), "app": s.appName, "agent": s.agent ?? "unknown",
                                         "id": s.id, "acquisitionId": s.id, "token": s.token,
                                         "scope": s.scope.rawValue,
                                         "coordSpace": s.coordSpace.rawValue, "icon": iconBase64Cached(pid: s.pid)]
                if let wid = s.wid { d["wid"] = Int(wid) }
                if let title = s.windowTitle { d["windowTitle"] = title }
                return d
            }
            // One row per app. The row addresses the pid, so Stop drops every
            // lease that app holds; the token shown is the app lease's, or the
            // first window lease's when the app was taken window by window.
            var apps: [[String: Any]] = []
            var seen = Set<Int32>()
            for s in SessionStore.shared.sessions() where s.scope != .foreground {
                if seen.contains(s.pid) {
                    if s.scope != .app { continue }
                    if let i = apps.firstIndex(where: { ($0["pid"] as? Int) == Int(s.pid) }) {
                        apps[i]["token"] = s.token
                    }
                    continue
                }
                seen.insert(s.pid)
                var a: [String: Any] = ["pid": Int(s.pid), "app": s.appName,
                                        "icon": iconBase64Cached(pid: s.pid), "token": s.token]
                if let touched = SessionStore.shared.lastActivity(pid: s.pid) {
                    a["lastActivity"] = Int(touched.timeIntervalSince1970 * 1000)
                }
                apps.append(a)
            }
            apps.sort { ($0["app"] as? String ?? "") < ($1["app"] as? String ?? "") }
            let ax = AXIsProcessTrusted(); let scr = CGPreflightScreenCaptureAccess()
            let missing = [ax ? nil : "Accessibility", scr ? nil : "Screen Recording"].compactMap { $0 }.joined(separator: " + ")
            let perms = (ax && scr) ? "Permissions OK (Accessibility + Screen Recording)." : "Missing: \(missing). Grant as dz.app via the button below."
            let profileSnapshot = StreamProfile.load()
            let payload: [String: Any] = ["version": dzVersion,
                                          "session": SessionController.shared.snapshot,
                                          "stream": StreamProfile.json(profileSnapshot),
                                          "port": Int(port), "url": "http://127.0.0.1:\(port)/mcp", "perms": perms,
                                          "ax": ax, "scr": scr, "sessions": sessions, "apps": apps,
                                          "appIcon": iconBase64Cached(pid: getpid()),
                                          "appPath": Bundle.main.bundleURL.path,
                                          "foreground": ForegroundCoordinator.shared.status(),
                                          "share": SessionController.shared.shareStatus,
                                          "remote": ["expose": MCPServer.expose,
                                                     "token": MCPServer.remoteToken,
                                                     "address": MCPServer.sharedAddress() ?? ""]]
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
                        dropSessionCaches(s.id)
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
            guard req.headers["x-dz-ui-token"] == uiToken else {
                send(fd, status: "403 Forbidden", body: Data("{\"error\":\"foreground approval must come from the dz menubar\"}".utf8))
                return
            }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let action = (obj["action"] as? String ?? "").lowercased()
            let requestId = (obj["requestId"] as? String) ?? ""
            var ok = false
            switch action {
            case "approve":
                ok = ForegroundCoordinator.shared.approve(requestId: requestId) == nil
                if ok { dropAllLeaseQueues() }
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
        if pathOnly == "/api/settings" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let updated = StreamProfile.save(StreamProfile.apply(obj, to: StreamProfile.load()))
            let payload: [String: Any] = ["ok": true, "stream": StreamProfile.json(updated)]
            send(fd, status: "200 OK", body: jsonData(payload), extraHeaders: [:])
            return
        }
        if pathOnly == "/api/session" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let action = (obj["action"] as? String ?? "").lowercased()
            let address = (obj["address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let profile = StreamProfile.load()
            // Starting a session touches AppKit, so it belongs on the main thread.
            DispatchQueue.main.async {
                switch action {
                case "host": SessionController.shared.startHosting(settings: profile)
                case "client" where !address.isEmpty: SessionController.shared.connect(to: address, settings: profile)
                case "stop": SessionController.shared.stop()
                default: break
                }
            }
            let payload: [String: Any] = ["ok": true, "requested": action]
            send(fd, status: "200 OK", body: jsonData(payload), extraHeaders: [:])
            return
        }
        if pathOnly == "/api/share" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let folder = (obj["folder"] as? String) ?? ""
            MCPServer.shareFolder = folder.isEmpty ? nil : folder
            if let auth = obj["auth"] as? Bool {
                UserDefaults.standard.set(auth, forKey: "dz.share.auth")
            }
            // Starting or stopping the share touches an app object, so the
            // answer is sent from the main thread once it has actually happened.
            DispatchQueue.main.async { [weak self] in
                SessionController.shared.updateShare()
                let payload: [String: Any] = ["ok": true, "share": SessionController.shared.shareStatus]
                self?.send(fd, status: "200 OK", body: jsonData(payload), extraHeaders: [:])
            }
            return
        }
        if pathOnly == "/api/remote" && req.method == "POST" {
            guard isJSON else { send(fd, status: "415 Unsupported Media Type", body: Data("{\"error\":\"application/json required\"}".utf8)); return }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let expose = (obj["expose"] as? Bool) ?? false
            MCPServer.expose = expose
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MCPServer.bindAll = expose
                self.stop()
                self.start(port: self.port)
            }
            let payload: [String: Any] = ["ok": true, "expose": expose,
                                          "token": MCPServer.remoteToken,
                                          "address": MCPServer.sharedAddress() ?? ""]
            send(fd, status: "200 OK", body: jsonData(payload), extraHeaders: [:])
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
        let incomingSession = headers["mcp-session-id"]
        switch method {
        case "initialize":
            let sid = UUID().uuidString
            let result: [String: Any] = [
                "protocolVersion": "2025-06-18",
                "serverInfo": ["name": "dz-mcp", "version": dzVersion],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": dzInstructions,
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

