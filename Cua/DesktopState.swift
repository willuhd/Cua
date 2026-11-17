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
    case notActive
}

final class ForegroundCoordinator {
    static let shared = ForegroundCoordinator()

    final class PendingResult: @unchecked Sendable {
        var result: Result<(sessionID: String, expiresAt: Date?), ForegroundRequestError>?
    }

    struct Pending {
        let requestId: String
        let agent: String
        let reason: String
        let requestedAt: Date
        let durationMs: Int // 0 = no expiry
        let coordSpace: CoordSpace
        let box: PendingResult
        let semaphore: DispatchSemaphore
    }

    struct Active {
        let requestId: String
        let sessionID: String
        let agent: String
        let startedAt: Date
        let expiresAt: Date?
    }

    struct HumanAbort {
        let sessionID: String
        let at: Date
    }

    private let lock = NSLock()
    private var pending: Pending?
    private var active: Active?
    private var expiry: DispatchWorkItem?
    private var humanAbort: HumanAbort?

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

    func request(agent: String, reason: String, durationMs: Int,
                 coordSpace: CoordSpace) throws -> (sessionID: String, expiresAt: Date?) {
        let requestId = UUID().uuidString.prefix(8).lowercased()
        let semaphore = DispatchSemaphore(value: 0)
        let box = PendingResult()
        lock.lock()
        if active != nil || pending != nil {
            lock.unlock()
            throw ForegroundRequestError.busy
        }
        humanAbort = nil
        let p = Pending(requestId: String(requestId), agent: agent, reason: reason,
                        requestedAt: Date(), durationMs: max(0, durationMs),
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

        // Hard preemption: wait for the current input gesture, then revoke
        // every background lease and create the one global foreground lease.
        guard InputGate.shared.wait(timeout: 5) else {
            p.box.result = .failure(.busy)
            p.semaphore.signal()
            lock.lock(); if pending?.requestId == p.requestId { pending = nil }; lock.unlock()
            return .busy
        }
        let session = SessionStore.shared.acquireForeground(coordSpace: p.coordSpace,
                                                            agentLabel: p.agent)
        let expiresAt: Date? = p.durationMs > 0
            ? Date().addingTimeInterval(Double(p.durationMs) / 1000.0)
            : nil
        let a = Active(requestId: p.requestId, sessionID: session.id,
                       agent: p.agent, startedAt: Date(), expiresAt: expiresAt)

        lock.lock()
        active = a
        p.box.result = .success((session.id, expiresAt))
        pending = nil
        lock.unlock()
        if let expiresAt = expiresAt { scheduleExpiry(a, expiresAt: expiresAt) }
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

    func stop() {
        HumanInputMonitor.shared.stop()
        lock.lock()
        guard let a = active else { lock.unlock(); return }
        active = nil
        expiry?.cancel()
        expiry = nil
        lock.unlock()
        teardown(a)
    }

    /// Human input took the pointer. Keep a short-lived revocation record so
    /// the agent's next call can get a fresh screenshot instead of a generic
    /// invalid-id error.
    func abortForHuman() {
        HumanInputMonitor.shared.stop()
        lock.lock()
        guard let a = active else { lock.unlock(); return }
        active = nil
        expiry?.cancel()
        expiry = nil
        humanAbort = HumanAbort(sessionID: a.sessionID, at: Date())
        lock.unlock()
        teardown(a)
    }

    func takeHumanAbort(sessionID: String) -> HumanAbort? {
        lock.lock(); defer { lock.unlock() }
        guard let h = humanAbort, h.sessionID.lowercased() == sessionID.lowercased() else { return nil }
        humanAbort = nil
        return h
    }

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
            var d: [String: Any] = ["mode": "active", "requestId": a.requestId,
                                    "sessionId": a.sessionID, "agent": a.agent,
                                    "app": "This Mac",
                                    "startedAt": Int(a.startedAt.timeIntervalSince1970 * 1000)]
            if let expiresAt = a.expiresAt {
                d["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
                d["remainingMs"] = max(0, Int(expiresAt.timeIntervalSinceNow * 1000))
            }
            return d
        }
        if let p = pending {
            return ["mode": "pending", "requestId": p.requestId, "agent": p.agent,
                    "reason": p.reason, "app": "This Mac",
                    "requestedAt": Int(p.requestedAt.timeIntervalSince1970 * 1000),
                    "durationMs": p.durationMs]
        }
        return ["mode": "idle"]
    }

    private func teardown(_ a: Active) {
        SessionStore.shared.remove(id: a.sessionID)
        SnapshotStore.shared.remove(sessionID: a.sessionID)
        AXIndexStore.shared.remove(sessionID: a.sessionID)
    }

    private func scheduleExpiry(_ a: Active, expiresAt: Date) {
        let item = DispatchWorkItem { [weak self] in
            self?.lock.lock()
            if self?.active?.sessionID == a.sessionID { self?.lock.unlock(); self?.stop() }
            else { self?.lock.unlock() }
        }
        lock.lock(); expiry = item; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Double(max(1, Int(expiresAt.timeIntervalSinceNow))), execute: item)
    }
}
