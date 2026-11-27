//
//  Terminal.swift
//  dz
//
//  A real shell on this Mac, driven over MCP.
//
//  This is a pty, not a command runner: the agent gets a shell that keeps its
//  state between calls, so it can cd, run something interactive, and read what
//  came back. One-shot commands are what ssh already does well, so the point
//  here is the session.
//
//  Output is kept in a ring so a chatty program cannot grow memory without
//  bound, and a cursor lets the agent read only what is new.
//

import Foundation

final class TerminalSession {
    let id: String
    private var master: Int32 = -1
    private var pid: pid_t = 0
    /// False when a pty could not be allocated and a pipe-backed shell was
    /// used instead. Everything works the same; interactive full-screen
    /// programs and line editing do not.
    private(set) var hasTTY = false
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var output = Data()
    private let lock = NSLock()
    private static let maxScrollback = 512 * 1024
    private var reader: DispatchSourceRead?

    init?(cwd: String? = nil, columns: Int = 100, rows: Int = 30) {
        id = String(UUID().uuidString.prefix(8).lowercased())
        var window = winsize(ws_row: UInt16(max(2, rows)), ws_col: UInt16(max(20, columns)),
                             ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = 0
        let child = forkpty(&fd, nil, nil, &window)
        if child < 0 {
            // A pty can be refused by the environment the app is launched in.
            // A pipe-backed shell still keeps state between calls, so fall back
            // rather than not offering a terminal at all.
            NSLog("dz.terminal: no pty (errno=%d, %@); using a pipe-backed shell",
                  errno, String(cString: strerror(errno)))
            if startPipeShell(cwd: cwd) { return }
            return nil
        }
        hasTTY = true
        if child == 0 {
            // Child: only exec-safe calls from here.
            if let cwd, !cwd.isEmpty { _ = chdir(cwd) }
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            var args: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-l"), nil]
            execv(shell, &args)
            _exit(127)
        }
        master = fd
        pid = child
        startReading()
    }

    @discardableResult
    private func startPipeShell(cwd: String?) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l"]
        if let cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            NSLog("dz.terminal: could not start a shell: %@", String(describing: error))
            return false
        }
        self.process = process
        self.stdinPipe = input
        self.stdoutPipe = output
        self.pid = process.processIdentifier

        let handle = output.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            self?.append(data)
        }
        return true
    }

    private func append(_ data: Data) {
        lock.lock()
        output.append(data)
        if output.count > Self.maxScrollback {
            output.removeFirst(output.count - Self.maxScrollback)
        }
        lock.unlock()
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue(label: "dz.term"))
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.master >= 0 { Darwin.close(self.master); self.master = -1 }
        }
        source.resume()
        reader = source
    }

    private func drain() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let n = Darwin.read(master, &chunk, chunk.count)
        guard n > 0 else {
            if n == 0 || (errno != EINTR && errno != EAGAIN) { reader?.cancel() }
            return
        }
        lock.lock()
        output.append(contentsOf: chunk[0..<n])
        if output.count > Self.maxScrollback {
            output.removeFirst(output.count - Self.maxScrollback)
        }
        lock.unlock()
    }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let stdinPipe {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            return
        }
        guard master >= 0 else { return }
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress! + sent, bytes.count - sent) }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            break
        }
    }

    func resize(columns: Int, rows: Int) {
        guard master >= 0 else { return }  // a pipe has no window size
        var window = winsize(ws_row: UInt16(max(2, rows)), ws_col: UInt16(max(20, columns)),
                             ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &window)
    }

    /// Output since a cursor, plus the cursor to pass next time.
    func readSince(_ cursor: Int) -> (text: String, cursor: Int) {
        lock.lock(); defer { lock.unlock() }
        let start = max(0, min(cursor, output.count))
        let slice = output.subdata(in: start..<output.count)
        return (String(decoding: slice, as: UTF8.self), output.count)
    }

    var isRunning: Bool {
        if let process { return process.isRunning }
        return pid > 0 && master >= 0
    }

    func close() {
        reader?.cancel()
        reader = nil
        if let process {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            self.process = nil
        }
        stdinPipe = nil
        stdoutPipe = nil
        if pid > 0 { kill(pid, SIGHUP); pid = 0 }
        if master >= 0 { Darwin.close(master); master = -1 }
    }
}

/// Owns the open terminals. One is enough for most work, but nothing here
/// assumes that.
final class TerminalStore {
    static let shared = TerminalStore()
    private var sessions: [String: TerminalSession] = [:]
    private let lock = NSLock()

    func open(cwd: String?, columns: Int, rows: Int) -> TerminalSession? {
        guard let session = TerminalSession(cwd: cwd, columns: columns, rows: rows) else { return nil }
        lock.lock(); sessions[session.id] = session; lock.unlock()
        return session
    }

    func session(_ id: String) -> TerminalSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    /// The most recently opened session, so a caller can omit the id.
    func anySession() -> TerminalSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.first
    }

    func close(_ id: String) {
        lock.lock(); let session = sessions.removeValue(forKey: id); lock.unlock()
        session?.close()
    }

    func closeAll() {
        lock.lock(); let all = sessions.values; sessions.removeAll(); lock.unlock()
        for session in all { session.close() }
    }
}
