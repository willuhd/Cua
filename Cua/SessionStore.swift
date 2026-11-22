import Cocoa
import Darwin

// MARK: – session store (in-memory only: leases + cursors)

/// 8 lowercase hex characters. Not cryptographic: short enough to read in a
/// menubar row and to type as an acquisitionId.
func shortID() -> String { String(UUID().uuidString.prefix(8).lowercased()) }

enum LeaseScope: String {
    case app
    case window
    case foreground
}

enum CoordSpace: String {
    case image
    case norm1000
    case screen
}

struct Session {
    var id: String
    /// The value the agent has to present. Same format as the id, generated
    /// once per lease so the menubar can show it and the user can read it back.
    var token: String
    var pid: Int32
    var agent: String?
    var appName: String
    var bid: String
    var scope: LeaseScope
    var wid: UInt32?
    var coordSpace: CoordSpace
    var windowTitle: String?
}

final class SessionStore {
    static let shared = SessionStore()
    private var lock = NSLock()
    private var byId: [String: Session] = [:]
    /// token -> lease id, so a presented token resolves without scanning.
    private var byToken: [String: String] = [:]
    private var cursors: [String: (Double, Double)] = [:]  // "session:wid" + "last:session"
    /// Last time a call touched this pid, kept after the lease is gone so the
    /// menubar can still say how long ago the app was used.
    private var lastTouch: [Int32: Date] = [:]

    enum LeaseError: Error {
        case held(Session)
        case invalidId(reason: String)
        case badRequest(String)
    }

    private func newSession(pid: Int32, scope: LeaseScope, wid: UInt32?, coordSpace: CoordSpace, agent: String?) -> Session {
        let name = pid == 0 ? "This Mac" : appNameForPid(pid)
        let bid = pid == 0 ? "?" : (NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })?.bundleIdentifier ?? "?")
        return Session(id: shortID(), token: shortID(), pid: pid, agent: agent, appName: name, bid: bid,
                       scope: scope, wid: wid, coordSpace: coordSpace,
                       windowTitle: wid.flatMap { windowTitle(wid: $0) })
    }

    func acquire(pid: Int32, scope: LeaseScope, wid: UInt32?, coordSpace: CoordSpace, agent: String?) -> Result<Session, LeaseError> {
        lock.lock(); defer { lock.unlock() }
        let existing = byId.values.filter { $0.pid == pid }
        switch scope {
        case .app:
            if let held = existing.first { return .failure(.held(held)) }
        case .window:
            guard let wid = wid, wid != 0 else { return .failure(.badRequest("window scope needs a wid")) }
            if let held = existing.first(where: { $0.scope == .app || $0.scope == .foreground }) {
                return .failure(.held(held))
            }
            if let held = existing.first(where: { $0.scope == .window && $0.wid == wid }) {
                return .failure(.held(held))
            }
        case .foreground:
            return .failure(.badRequest("foreground grants are created through request_foreground"))
        }
        let s = newSession(pid: pid, scope: scope, wid: (scope == .app ? nil : wid), coordSpace: coordSpace, agent: agent)
        byId[s.id] = s
        byToken[s.token.lowercased()] = s.id
        return .success(s)
    }

    /// Foreground is a global, hard preemption: every existing background
    /// lease is revoked before the foreground session is created. The caller
    /// must have user approval and the global input lock already held.
    func acquireForeground(coordSpace: CoordSpace, agent: String?) -> Session {
        lock.lock(); defer { lock.unlock() }
        byId.removeAll()
        byToken.removeAll()
        cursors.removeAll()
        let s = newSession(pid: 0, scope: .foreground, wid: nil, coordSpace: coordSpace, agent: agent)
        byId[s.id] = s
        byToken[s.token.lowercased()] = s.id
        return s
    }

    private func pidAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
    private func currentBid(_ pid: Int32) -> String? {
        NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })?.bundleIdentifier
    }

    func validate(id: String) -> Result<Session, LeaseError> {
        lock.lock(); defer { lock.unlock() }
        guard let s = lookupLocked(id) else {
            return .failure(.invalidId(reason: "no active lease with this acquisitionId or token"))
        }
        if s.scope == .foreground { return .success(s) }
        if !pidAlive(s.pid) {
            forgetLocked(s)
            return .failure(.invalidId(reason: "the target app exited; acquire again"))
        }
        if s.bid != "?", let now = currentBid(s.pid), now != s.bid {
            forgetLocked(s)
            return .failure(.invalidId(reason: "the pid now belongs to a different app; acquire again"))
        }
        return .success(s)
    }

    func release(id: String) -> Result<Void, LeaseError> {
        lock.lock(); defer { lock.unlock() }
        guard let s = lookupLocked(id) else {
            return .failure(.invalidId(reason: "no active lease with this acquisitionId or token"))
        }
        forgetLocked(s)
        return .success(())
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        if let s = lookupLocked(id) { forgetLocked(s) }
    }

    /// UI action. With a wid, free that window lease; without one, free every
    /// lease belonging to the pid (the app row's "Free all").
    func free(pid: Int32, wid: UInt32? = nil) {
        lock.lock(); defer { lock.unlock() }
        let victims: [Session]
        if let wid = wid {
            victims = byId.values.filter { $0.pid == pid && $0.wid == wid }
        } else {
            victims = byId.values.filter { $0.pid == pid }
        }
        for s in victims { forgetLocked(s) }
    }


    func sessions() -> [Session] {
        lock.lock(); defer { lock.unlock() }
        var live: [Session] = []
        let all = Array(byId.values)
        for s in all {
            if s.scope == .foreground {
                live.append(s)
                continue
            }
            if !pidAlive(s.pid) { forgetLocked(s); continue }
            if s.bid != "?", let now = currentBid(s.pid), now != s.bid { forgetLocked(s); continue }
            live.append(s)
        }
        return live.sorted {
            if $0.appName != $1.appName { return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            if $0.scope != $1.scope { return $0.scope == .app && $1.scope != .app }
            return ($0.wid ?? 0) < ($1.wid ?? 0)
        }
    }

    func find(id: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return lookupLocked(id)
    }

    /// A presented value is either the lease id or the token shown for it in
    /// the menubar. Both name one lease and nothing else.
    private func lookupLocked(_ presented: String) -> Session? {
        let v = presented.lowercased()
        if let s = byId[v] { return s }
        if let id = byToken[v] { return byId[id] }
        return nil
    }

    private func forgetLocked(_ s: Session) {
        byId.removeValue(forKey: s.id)
        byToken.removeValue(forKey: s.token.lowercased())
        removeCursorsLocked(sessionID: s.id)
    }

    /// Every call that reaches the whole Mac from a grant lands here, so the
    /// menubar can say when a pid was last used even after its lease is gone.
    func noteActivity(pid: Int32) {
        guard pid != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        lastTouch[pid] = Date()
    }

    func lastActivity(pid: Int32) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return lastTouch[pid]
    }


    func saveCursor(sessionID: String, wid: UInt32, x: Double, y: Double) {
        lock.lock(); defer { lock.unlock() }
        cursors["\(sessionID):\(wid)"] = (x, y)
        cursors["last:\(sessionID)"] = (x, y)
    }

    func lastCursor(sessionID: String, wid: UInt32? = nil) -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        if let wid = wid, let c = cursors["\(sessionID):\(wid)"] { return c }
        return cursors["last:\(sessionID)"]
    }

    private func removeCursorsLocked(sessionID: String) {
        let keys = cursors.keys.filter { $0.hasPrefix("\(sessionID):") || $0 == "last:\(sessionID)" }
        for key in keys { cursors.removeValue(forKey: key) }
    }
}
