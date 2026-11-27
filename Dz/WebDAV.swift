//
//  WebDAV.swift
//  dz
//
//  Serves a folder over WebDAV so the other Mac can mount it under /Volumes.
//
//  This is the honest way to get a real volume without an FSKit extension:
//  macOS ships mount_webdav, the filesystem behaves like a disk because it is
//  a mount, and nothing needs an entitlement from Apple.
//
//  Only the verbs Finder actually uses are implemented: PROPFIND, GET, HEAD,
//  PUT, DELETE, MKCOL, MOVE, plus LOCK/UNLOCK so that Office and Finder will
//  write. Everything requires the session token as a Basic auth password,
//  because Tailscale proves which device is calling, not who is using it.
//

import Foundation

final class WebDAVServer {
    private let root: URL
    private let port: UInt16
    /// Empty means no authentication, which is only sensible on a link that
    /// already authenticates both ends, such as a tailnet.
    private let token: String
    private var listenFd: Int32 = -1
    private let queue = DispatchQueue(label: "dz.webdav", qos: .utility, attributes: .concurrent)
    private let acceptQueue = DispatchQueue(label: "dz.webdav.accept", qos: .utility)
    private var running = false
    private let lock = NSLock()

    init(root: URL, port: UInt16, token: String) {
        self.root = root.standardizedFileURL
        self.port = port
        self.token = token
    }

    private func makeListener() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0, Darwin.listen(fd, 64) == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    func start() -> Bool {
        guard let fd = makeListener() else { return false }
        lock.lock(); listenFd = fd; running = true; lock.unlock()
        acceptQueue.async { [weak self] in
            while true {
                guard let self else { return }
                self.lock.lock(); let current = self.listenFd; let alive = self.running; self.lock.unlock()
                guard alive, current >= 0 else { return }
                var caddr = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let client = withUnsafeMutablePointer(to: &caddr) { accept(current, $0, &len) }
                if client < 0 { if errno == EINTR { continue }; usleep(10000); continue }
                var nosig: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                self.queue.async { self.handle(client) }
            }
        }
        return true
    }

    func stop() {
        lock.lock()
        running = false
        if listenFd >= 0 { shutdown(listenFd, SHUT_RDWR); Darwin.close(listenFd); listenFd = -1 }
        lock.unlock()
    }

    // MARK: - request plumbing

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func handle(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // webdavfs keeps one connection for the whole session and treats an
        // abrupt close as a dead volume, so requests are served in a loop.
        var buffer = Data()
        while true {
            guard let request = readRequest(fd, buffer: &buffer) else { return }
            serve(fd, request)
        }
    }

    private func serve(_ fd: Int32, _ request: Request) {
        guard let request = Optional(request) else { return }
        NSLog("dz.webdav: %@ %@ auth=%@ depth=%@", request.method, request.path,
              request.headers["authorization"] == nil ? "none" : "yes",
              request.headers["depth"] ?? "-")

        // Basic auth: user is ignored, password is the session token.
        if token.isEmpty {
            respond(fd, request)
            return
        }
        if let auth = request.headers["authorization"], auth.hasPrefix("Basic "),
           let decoded = Data(base64Encoded: String(auth.dropFirst(6))),
           let pair = String(data: decoded, encoding: .utf8),
           let password = pair.split(separator: ":", maxSplits: 1).last,
           String(password) == token {
            respond(fd, request)
        } else {
            write(fd, status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"dz\""], body: Data())
        }
    }

    private func readRequest(_ fd: Int32, buffer: inout Data) -> Request? {
        var chunk = [UInt8](repeating: 0, count: 32768)
        while true {
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                guard !lines.isEmpty else { return nil }
                let parts = lines.removeFirst().split(separator: " ")
                guard parts.count >= 2 else { return nil }
                var headers: [String: String] = [:]
                for line in lines {
                    if let colon = line.firstIndex(of: ":") {
                        let key = line[line.startIndex..<colon].lowercased()
                        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[key] = value
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = headerEnd.upperBound
                while buffer.distance(from: buffer.startIndex, to: buffer.endIndex) < buffer.distance(from: buffer.startIndex, to: bodyStart) + length {
                    let n = recv(fd, &chunk, chunk.count, 0)
                    if n <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<n])
                }
                let headLength = buffer.distance(from: buffer.startIndex, to: bodyStart)
                guard buffer.count >= headLength + length else { return nil }
                let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: length))
                // This connection is reused, so the request has to leave the
                // buffer or it will be parsed again forever.
                buffer.removeFirst(headLength + length)
                return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
            }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func write(_ fd: Int32, status: String, headers: [String: String], body: Data) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        var response = "HTTP/1.1 " + status + "\r\n"
        response += "Date: " + formatter.string(from: Date()) + "\r\n"
        response += "Server: dz\r\n"
        // Clients check for the DAV header on every response, not only OPTIONS.
        response += "DAV: 1, 2\r\n"
        response += "Content-Length: " + String(body.count) + "\r\n"
        response += "Connection: close\r\n"
        for (key, value) in headers { response += key + ": " + value + "\r\n" }
        response += "\r\n"
        var out = Data(response.utf8)
        out.append(body)
        var sent = 0
        let bytes = [UInt8](out)
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            break
        }
    }

    // MARK: - paths

    private func localURL(for path: String) -> URL? {
        let decoded = path.removingPercentEncoding ?? path
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        // Refuse anything that escapes the share.
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    private func href(for url: URL, isDirectory: Bool) -> String {
        var relative = url.path
        if relative.hasPrefix(root.path) { relative = String(relative.dropFirst(root.path.count)) }
        var encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        if encoded.isEmpty { encoded = "/" }
        // A collection's href must end in a slash, or clients treat it as a file.
        if isDirectory, !encoded.hasSuffix("/") { encoded += "/" }
        return encoded
    }

    private func response(_ fd: Int32, _ request: Request) {
        respond(fd, request)
    }

    private func respond(_ fd: Int32, _ request: Request) {
        guard let target = localURL(for: request.path) else {
            write(fd, status: "403 Forbidden", headers: [:], body: Data())
            return
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: target.path, isDirectory: &isDirectory)

        switch request.method {
        case "OPTIONS":
            write(fd, status: "200 OK", headers: ["DAV": "1, 2", "Allow": "OPTIONS, PROPFIND, GET, HEAD, PUT, DELETE, MKCOL, MOVE, LOCK, UNLOCK"], body: Data())

        case "PROPFIND":
            guard exists else { write(fd, status: "404 Not Found", headers: [:], body: Data()); return }
            let depth = request.headers["depth"] ?? "1"
            var entries: [URL] = [target]
            if depth != "0", isDirectory.boolValue,
               let children = try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
                entries.append(contentsOf: children.sorted { $0.lastPathComponent < $1.lastPathComponent })
            }
            var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
            // WebDAV requires RFC 1123 dates. ISO 8601 parses as nothing and
            // macOS silently drops the volume.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            for entry in entries {
                var childDirectory: ObjCBool = false
                _ = fm.fileExists(atPath: entry.path, isDirectory: &childDirectory)
                let attributes = (try? fm.attributesOfItem(atPath: entry.path)) ?? [:]
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                let modified = attributes[.modificationDate] as? Date ?? Date()
                xml += "<D:response><D:href>" + href(for: entry, isDirectory: childDirectory.boolValue) + "</D:href><D:propstat><D:prop>"
                xml += "<D:resourcetype>" + (childDirectory.boolValue ? "<D:collection/>" : "") + "</D:resourcetype>"
                // A collection has no length of its own.
                if !childDirectory.boolValue {
                    xml += "<D:getcontentlength>" + String(size) + "</D:getcontentlength>"
                }
                xml += "<D:getlastmodified>" + formatter.string(from: modified) + "</D:getlastmodified>"
                let modifier = DateFormatter()
                modifier.locale = Locale(identifier: "en_US_POSIX")
                modifier.timeZone = TimeZone(identifier: "GMT")
                modifier.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                xml += "<D:creationdate>" + modifier.string(from: modified) + "</D:creationdate>"
                // macOS asks for an etag and a display name; omitting them is
                // enough for it to reject the volume.
                let etag = String(format: "\"%@\"", String(entry.path.hashValue))
                xml += "<D:getetag>" + etag + "</D:getetag>"
                xml += "<D:displayname>" + entry.lastPathComponent + "</D:displayname>"
                if !childDirectory.boolValue {
                    xml += "<D:getcontenttype>application/octet-stream</D:getcontenttype>"
                }
                // We advertise class 2, so lock support has to be described.
                xml += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope>"
                xml += "<D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
                xml += "<D:lockdiscovery/>"
                xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
            }
            xml += "</D:multistatus>"
            write(fd, status: "207 Multi-Status", headers: ["Content-Type": "text/xml; charset=\"utf-8\""], body: Data(xml.utf8))

        case "GET", "HEAD":
            guard exists, !isDirectory.boolValue else { write(fd, status: "404 Not Found", headers: [:], body: Data()); return }
            let data = (try? Data(contentsOf: target)) ?? Data()
            write(fd, status: "200 OK", headers: ["Content-Type": "application/octet-stream"],
                  body: request.method == "HEAD" ? Data() : data)

        case "PUT":
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try request.body.write(to: target)
                write(fd, status: "201 Created", headers: [:], body: Data())
            } catch {
                write(fd, status: "500 Internal Server Error", headers: [:], body: Data())
            }

        case "MKCOL":
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                write(fd, status: "201 Created", headers: [:], body: Data())
            } catch {
                write(fd, status: "405 Method Not Allowed", headers: [:], body: Data())
            }

        case "DELETE":
            do {
                try fm.removeItem(at: target)
                write(fd, status: "204 No Content", headers: [:], body: Data())
            } catch {
                write(fd, status: "404 Not Found", headers: [:], body: Data())
            }

        case "MOVE":
            guard let destination = request.headers["destination"],
                  let decoded = destination.removingPercentEncoding,
                  let url = URL(string: decoded),
                  let newTarget = localURL(for: url.path) else {
                write(fd, status: "400 Bad Request", headers: [:], body: Data())
                return
            }
            do {
                try fm.moveItem(at: target, to: newTarget)
                write(fd, status: "201 Created", headers: [:], body: Data())
            } catch {
                write(fd, status: "409 Conflict", headers: [:], body: Data())
            }

        case "LOCK":
            let lockToken = "opaquelocktoken:" + UUID().uuidString
            let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>"
                + "<D:locktype><D:write/></D:locktype><D:locktoken><D:href>" + lockToken + "</D:href></D:locktoken>"
                + "<D:depth>infinity</D:depth></D:activelock></D:lockdiscovery></D:prop>"
            write(fd, status: "200 OK", headers: ["Lock-Token": "<" + lockToken + ">",
                                                   "Content-Type": "text/xml; charset=\"utf-8\""],
                  body: Data(xml.utf8))

        case "UNLOCK":
            write(fd, status: "204 No Content", headers: [:], body: Data())

        default:
            NSLog("dz.webdav: unhandled %@", request.method)
            write(fd, status: "405 Method Not Allowed", headers: [:], body: Data())
        }
    }
}
