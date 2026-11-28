import Cocoa
import CoreGraphics

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

/// Everything a lease cached is keyed by its id and lives in two stores;
/// dropping a lease drops both, so no caller can free half of it.
func dropSessionCaches(_ sessionID: String) {
    SnapshotStore.shared.remove(sessionID: sessionID)
    AXIndexStore.shared.remove(sessionID: sessionID)
}

// MARK: – global input admission
final class InputGate {
    static let shared = InputGate()
    private let condition = NSCondition()
    private var busy = false

    private func acquire() {
        condition.lock()
        while busy { condition.wait() }
        busy = true
        condition.unlock()
    }

    private func release() {
        condition.lock()
        busy = false
        condition.broadcast()
        condition.unlock()
    }

    func withLock<T>(_ body: () -> T) -> T {
        acquire()
        defer { release() }
        return body()
    }
}
/// Human input invalidates the foreground observation, not the grant. The
/// monitor is installed only while a grant is active; pointer movement alone
/// is not a takeover signal, so it watches clicks, scrolls, and keys only.
final class HumanInputMonitor {
    static let shared = HumanInputMonitor()
    private var monitor: Any?

    func start() {
        // Approval arrives on an HTTP worker; NSEvent monitors are installed
        // and removed on the main thread.
        DispatchQueue.main.async { [weak self] in self?.install() }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in self?.remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,
                                                               .rightMouseDown, .otherMouseDown,
                                                               .scrollWheel, .keyDown]) { event in
            guard ForegroundCoordinator.shared.isActive else { return }
            // Only events this app tagged are ours. Anything else is human,
            // including an event that arrives without a CGEvent.
            if let cg = event.cgEvent,
               cg.getIntegerValueField(.eventSourceUserData) == dzSyntheticEventTag { return }
            ForegroundCoordinator.shared.noteHumanInput()
        }
    }

    private func remove() {
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
        var result: Result<String, ForegroundRequestError>?
    }

    struct Pending {
        let requestId: String
        let agent: String
        let reason: String
        let requestedAt: Date
        let coordSpace: CoordSpace
        let box: PendingResult
        let semaphore: DispatchSemaphore
    }

    struct Active {
        let requestId: String
        let sessionID: String
        let agent: String
        let startedAt: Date
    }

    private let lock = NSLock()
    var onChange: (() -> Void)?
    private var pending: Pending?
    private var active: Active?
    private var humanEpoch: Int = 0
    private var observedEpoch: Int = 0
    private var hasObservation = false

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active != nil
    }

    var activeSessionID: String? {
        lock.lock(); defer { lock.unlock() }
        return active?.sessionID
    }

    /// The grant answers to its lease id and to the token the menubar shows,
    /// which are the same string.
    func namesGrant(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let a = active else { return false }
        return a.sessionID.lowercased() == id.lowercased()
    }

    func request(agent: String, reason: String,
                 coordSpace: CoordSpace) throws -> String {
        let requestId = shortID()
        let semaphore = DispatchSemaphore(value: 0)
        let box = PendingResult()
        lock.lock()
        if active != nil || pending != nil {
            lock.unlock()
            throw ForegroundRequestError.busy
        }
        humanEpoch = 0
        observedEpoch = 0
        hasObservation = false
        let p = Pending(requestId: requestId, agent: agent, reason: reason,
                        requestedAt: Date(), coordSpace: coordSpace, box: box, semaphore: semaphore)
        pending = p
        lock.unlock()
        onChange?()

        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            lock.lock()
            if pending?.requestId == p.requestId {
                pending = nil
                lock.unlock()
                onChange?()
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

        // Only clear our own request: a deny wakes us, and a new request can
        // already be pending by the time this waiter runs again.
        lock.lock()
        if pending?.requestId == p.requestId { pending = nil }
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

        // Hard preemption: wait for the current gesture, clear cached state from
        // every background lease, and create the one global foreground lease.
        // The commit happens under the gate and under one lock, so nothing can
        // acquire a background lease between the revoke and the grant, and a
        // request that expired while we waited cannot hand out an unheld grant.
        let committed: Active? = InputGate.shared.withLock {
            lock.lock()
            guard pending?.requestId == p.requestId else {
                lock.unlock()
                return nil
            }
            SnapshotStore.shared.removeAll()
            AXIndexStore.shared.removeAll()
            let session = SessionStore.shared.acquireForeground(coordSpace: p.coordSpace,
                                                                agent: p.agent)
            let a = Active(requestId: p.requestId, sessionID: session.id,
                           agent: p.agent, startedAt: Date())
            humanEpoch = 0
            observedEpoch = 0
            hasObservation = false
            active = a
            p.box.result = .success(session.id)
            pending = nil
            lock.unlock()
            return a
        }
        guard committed != nil else { return .notActive }
        HumanInputMonitor.shared.start()
        p.semaphore.signal()
        onChange?()
        return nil
    }

    func deny(requestId: String) -> Bool {
        lock.lock()
        guard let p = pending, p.requestId == requestId else { lock.unlock(); return false }
        pending = nil
        p.box.result = .failure(.denied)
        lock.unlock()
        p.semaphore.signal()
        onChange?()
        return true
    }

    func stop() {
        HumanInputMonitor.shared.stop()
        lock.lock()
        guard let a = active else { lock.unlock(); return }
        active = nil
        lock.unlock()
        teardown(a)
    }

    func noteHumanInput() {
        var changed = false
        lock.lock()
        if active != nil {
            let wasClean = hasObservation && observedEpoch == humanEpoch
            humanEpoch += 1
            changed = wasClean
        }
        lock.unlock()
        if changed { onChange?() }
    }

    func observationEpoch() -> Int {
        lock.lock(); defer { lock.unlock() }
        return humanEpoch
    }

    func noteObservation(at epoch: Int) {
        var changed = false
        lock.lock()
        if active != nil {
            changed = !hasObservation || observedEpoch != epoch
            observedEpoch = epoch
            hasObservation = true
        }
        lock.unlock()
        if changed { onChange?() }
    }

    func observationStatus() -> (needsScreenshot: Bool, dirty: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard active != nil else { return (false, false) }
        if !hasObservation { return (true, false) }
        return (false, observedEpoch != humanEpoch)
    }

    /// Ends the grant when the presented id (or token) is the grant's own.
    func release(id: String) -> Bool {
        lock.lock()
        guard let a = active, a.sessionID.lowercased() == id.lowercased() else { lock.unlock(); return false }
        lock.unlock()
        stop()
        return true
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let a = active {
            let observation = !hasObservation ? "needs-screenshot"
                : (observedEpoch == humanEpoch ? "clean" : "stale")
            let d: [String: Any] = ["mode": "active", "requestId": a.requestId,
                                    "sessionId": a.sessionID, "agent": a.agent,
                                    "app": "This Mac", "observation": observation,
                                    "startedAt": Int(a.startedAt.timeIntervalSince1970 * 1000)]
            return d
        }
        if let p = pending {
            return ["mode": "pending", "requestId": p.requestId, "agent": p.agent,
                    "reason": p.reason, "app": "This Mac",
                    "requestedAt": Int(p.requestedAt.timeIntervalSince1970 * 1000)]
        }
        return ["mode": "idle"]
    }

    private func teardown(_ a: Active) {
        SessionStore.shared.remove(id: a.sessionID)
        dropSessionCaches(a.sessionID)
    }

}
