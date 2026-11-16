import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – snapshot cache (last full-resolution capture per lease/window)
struct Snapshot {
    let id: String
    let sessionID: String
    let wid: UInt32
    let source: CGImage
    let windowBounds: CGRect
    /// Normalized 0..1 rectangle of the window covered by the image.
    let region: CGRect
    let imageWidth: Int
    let imageHeight: Int
    let coordSpace: CoordSpace
    let capturedAt: Date
}

final class SnapshotStore {
    static let shared = SnapshotStore()
    private let lock = NSLock()
    private var byKey: [String: Snapshot] = [:]
    private var order: [String] = []
    private let maxSnapshots = 4

    private func key(_ sessionID: String, _ wid: UInt32) -> String { "\(sessionID):\(wid)" }

    func save(_ snapshot: Snapshot) {
        lock.lock(); defer { lock.unlock() }
        let k = key(snapshot.sessionID, snapshot.wid)
        byKey[k] = snapshot
        order.removeAll { $0 == k }
        order.append(k)
        while order.count > maxSnapshots {
            let old = order.removeFirst()
            byKey.removeValue(forKey: old)
        }
    }

    func get(sessionID: String, wid: UInt32) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        if SessionStore.shared.find(id: sessionID) == nil {
            let prefix = "\(sessionID):"
            let keys = byKey.keys.filter { $0.hasPrefix(prefix) }
            for k in keys { byKey.removeValue(forKey: k) }
            order.removeAll { $0.hasPrefix(prefix) }
            return nil
        }
        return byKey[key(sessionID, wid)]
    }

    func removeAll() {
        lock.lock(); byKey.removeAll(); order.removeAll(); lock.unlock()
    }

    func remove(sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        let prefix = "\(sessionID):"
        let keys = byKey.keys.filter { $0.hasPrefix(prefix) }
        for k in keys { byKey.removeValue(forKey: k) }
        order.removeAll { $0.hasPrefix(prefix) }
        let stale = byKey.keys.filter { key in
            let id = key.split(separator: ":").first.map(String.init) ?? ""
            return SessionStore.shared.find(id: id) == nil
        }
        for k in stale { byKey.removeValue(forKey: k) }
        order.removeAll { byKey[$0] == nil }
    }
}

// MARK: – global input admission
final class InputGate {
    static let shared = InputGate()
    private let condition = NSCondition()
    private var depth = 0

    func withLock<T>(_ body: () -> T) -> T {
        condition.lock()
        depth += 1
        condition.unlock()
        defer {
            condition.lock()
            depth -= 1
            if depth == 0 { condition.broadcast() }
            condition.unlock()
        }
        return body()
    }

    var isHeld: Bool {
        condition.lock(); defer { condition.unlock() }
        return depth > 0
    }

    /// Wait for the current input gesture to finish. New gestures are blocked
    /// by the lease state while a foreground approval is being committed.
    func wait(timeout: TimeInterval = 5) -> Bool {
        condition.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while depth > 0 {
            if !condition.wait(until: deadline) {
                condition.unlock()
                return false
            }
        }
        condition.unlock()
        return true
    }
}

/// Human input always wins over an agent's foreground grant. The monitor is
/// installed only while a grant is active; pointer movement alone is not a
/// takeover signal, so it watches clicks, scrolls, and keys only.
final class HumanInputMonitor {
    static let shared = HumanInputMonitor()
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,
                                                               .rightMouseDown, .otherMouseDown,
                                                               .scrollWheel, .keyDown]) { _ in
            guard ForegroundCoordinator.shared.isActive, !InputGate.shared.isHeld else { return }
            // Ignore the small click/key tail from approving in the menubar.
            if let started = ForegroundCoordinator.shared.activeStartedAt,
               Date().timeIntervalSince(started) < 0.8 { return }
            DispatchQueue.global(qos: .userInitiated).async { ForegroundCoordinator.shared.abortForHuman() }
        }
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: – foreground/global mode
enum ForegroundRequestError: Error {
    case busy
    case denied
    case timeout
    case targetGone
    case notActive
}

final class ForegroundCoordinator {
    static let shared = ForegroundCoordinator()

    final class PendingResult: @unchecked Sendable {
        var result: Result<(sessionID: String, expiresAt: Date), ForegroundRequestError>?
    }

    struct Pending {
        let requestId: String
        let pid: Int32
        let wid: UInt32
        let appName: String
        let agent: String
        let reason: String
        let requestedAt: Date
        let durationMs: Int
        let coordSpace: CoordSpace
        let box: PendingResult
        let semaphore: DispatchSemaphore
    }

    struct Active {
        let requestId: String
        let sessionID: String
        let pid: Int32
        let wid: UInt32
        let appName: String
        let agent: String
        let startedAt: Date
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var pending: Pending?
    private var active: Active?
    private var expiry: DispatchWorkItem?
    private var previousFocus: FocusSnapshot?
    private var previousCursor: CGPoint?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active != nil
    }

    var activeSessionID: String? {
        lock.lock(); defer { lock.unlock() }
        return active?.sessionID
    }

    var activeStartedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return active?.startedAt
    }

    func request(pid: Int32, wid: UInt32, appName: String, agent: String,
                 reason: String, durationMs: Int, coordSpace: CoordSpace) throws -> (sessionID: String, expiresAt: Date) {
        let requestId = UUID().uuidString.prefix(8).lowercased()
        let semaphore = DispatchSemaphore(value: 0)
        let box = PendingResult()
        lock.lock()
        if active != nil || pending != nil {
            lock.unlock()
            throw ForegroundRequestError.busy
        }
        let p = Pending(requestId: String(requestId), pid: pid, wid: wid, appName: appName,
                        agent: agent, reason: reason, requestedAt: Date(),
                        durationMs: max(10_000, min(durationMs, 300_000)),
                        coordSpace: coordSpace, box: box, semaphore: semaphore)
        pending = p
        lock.unlock()

        if semaphore.wait(timeout: .now() + 90) == .timedOut {
            lock.lock()
            if pending?.requestId == p.requestId {
                pending = nil
                lock.unlock()
                throw ForegroundRequestError.timeout
            }
            lock.unlock()
            if let result = box.result {
                switch result {
                case .success(let v): return v
                case .failure(let e): throw e
                }
            }
            throw ForegroundRequestError.timeout
        }

        lock.lock()
        pending = nil
        lock.unlock()
        switch box.result {
        case .success(let v): return v
        case .failure(let e): throw e
        case .none: throw ForegroundRequestError.timeout
        }
    }

    func approve(requestId: String) -> ForegroundRequestError? {
        lock.lock()
        guard let p = pending, p.requestId == requestId else {
            lock.unlock()
            return .notActive
        }
        lock.unlock()

        guard windowOwnerPid(wid: p.wid) == p.pid else {
            p.box.result = .failure(.targetGone)
            p.semaphore.signal()
            lock.lock(); if pending?.requestId == p.requestId { pending = nil }; lock.unlock()
            return .targetGone
        }

        // One-click hard preemption: wait for the current input gesture, then
        // revoke every background lease and create the foreground session.
        guard InputGate.shared.wait(timeout: 5) else {
            p.box.result = .failure(.busy)
            p.semaphore.signal()
            lock.lock(); if pending?.requestId == p.requestId { pending = nil }; lock.unlock()
            return .busy
        }
        previousFocus = snapshotFocus(readKeyWindow: true)
        previousCursor = CGEvent(source: nil)?.location
        let session = SessionStore.shared.acquireForeground(pid: p.pid, wid: p.wid,
                                                            coordSpace: p.coordSpace,
                                                            agentLabel: p.agent)
        activateForeground(pid: p.pid, wid: p.wid)
        let expiresAt = Date().addingTimeInterval(Double(p.durationMs) / 1000.0)
        let a = Active(requestId: p.requestId, sessionID: session.id, pid: p.pid, wid: p.wid,
                       appName: p.appName, agent: p.agent, startedAt: Date(), expiresAt: expiresAt)

        lock.lock()
        active = a
        p.box.result = .success((session.id, expiresAt))
        pending = nil
        lock.unlock()
        scheduleExpiry(a)
        HumanInputMonitor.shared.start()
        p.semaphore.signal()
        return nil
    }

    func deny(requestId: String) -> Bool {
        lock.lock()
        guard let p = pending, p.requestId == requestId else { lock.unlock(); return false }
        pending = nil
        p.box.result = .failure(.denied)
        lock.unlock()
        p.semaphore.signal()
        return true
    }

    func stop(restore: Bool = true) {
        HumanInputMonitor.shared.stop()
        lock.lock()
        guard let a = active else { lock.unlock(); return }
        active = nil
        expiry?.cancel()
        expiry = nil
        let prev = previousFocus
        let prevCursor = previousCursor
        previousFocus = nil
        previousCursor = nil
        lock.unlock()
        SessionStore.shared.remove(id: a.sessionID)
        SnapshotStore.shared.remove(sessionID: a.sessionID)
        AXIndexStore.shared.remove(sessionID: a.sessionID)
        if restore { restoreForeground(prev: prev, targetWid: a.wid, cursor: prevCursor) }
    }

    /// Human input already took the pointer/focus; never yank it back.
    func abortForHuman() { stop(restore: false) }

    func release(sessionID: String) -> Bool {
        lock.lock()
        guard let a = active, a.sessionID.lowercased() == sessionID.lowercased() else { lock.unlock(); return false }
        lock.unlock()
        stop()
        return true
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let a = active {
            return ["mode": "active", "requestId": a.requestId, "sessionId": a.sessionID,
                    "pid": Int(a.pid), "wid": Int(a.wid), "app": a.appName, "agent": a.agent,
                    "startedAt": Int(a.startedAt.timeIntervalSince1970 * 1000),
                    "expiresAt": Int(a.expiresAt.timeIntervalSince1970 * 1000),
                    "remainingMs": max(0, Int(a.expiresAt.timeIntervalSinceNow * 1000))]
        }
        if let p = pending {
            return ["mode": "pending", "requestId": p.requestId, "pid": Int(p.pid), "wid": Int(p.wid),
                    "app": p.appName, "agent": p.agent, "reason": p.reason,
                    "requestedAt": Int(p.requestedAt.timeIntervalSince1970 * 1000),
                    "durationMs": p.durationMs]
        }
        return ["mode": "idle"]
    }

    private func scheduleExpiry(_ a: Active) {
        let item = DispatchWorkItem { [weak self] in
            self?.lock.lock()
            if self?.active?.sessionID == a.sessionID { self?.lock.unlock(); self?.stop() }
            else { self?.lock.unlock() }
        }
        lock.lock(); expiry = item; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Double(max(1, Int(a.expiresAt.timeIntervalSinceNow))), execute: item)
    }

    private func activateForeground(pid: Int32, wid: UInt32) {
        let activate: () -> Void = {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        if Thread.isMainThread { activate() } else { DispatchQueue.main.sync(execute: activate) }
        _ = raiseWindow(pid: pid, wid: wid)
        usleep(150_000)
    }

    private func restoreForeground(prev: FocusSnapshot?, targetWid: UInt32, cursor: CGPoint?) {
        if let cursor = cursor {
            CGWarpMouseCursorPosition(cursor)
        }
        if let prev = prev {
            _ = restoreFocus(to: prev, targetWid: targetWid)
        }
    }
}
