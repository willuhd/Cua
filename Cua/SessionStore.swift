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
    private var cursors: [String: (Double, Double)] = [:]  // "session:wid" + "last:session"

    enum LeaseError: Error {
        case held(Session)
        case invalidId(reason: String)
        case badRequest(String)
    }

    private func newSession(pid: Int32, scope: LeaseScope, wid: UInt32?, coordSpace: CoordSpace, agent: String?) -> Session {
        let name = pid == 0 ? "This Mac" : appNameForPid(pid)
        let bid = pid == 0 ? "?" : (NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })?.bundleIdentifier ?? "?")
        return Session(id: shortID(), pid: pid, agent: agent, appName: name, bid: bid,
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
        return .success(s)
    }

    /// Foreground is a global, hard preemption: every existing background
    /// lease is revoked before the foreground session is created. The caller
    /// must have user approval and the global input lock already held.
    func acquireForeground(coordSpace: CoordSpace, agent: String?) -> Session {
        lock.lock(); defer { lock.unlock() }
        byId.removeAll()
        cursors.removeAll()
        let s = newSession(pid: 0, scope: .foreground, wid: nil, coordSpace: coordSpace, agent: agent)
        byId[s.id] = s
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
        guard let s = byId[id.lowercased()] else {
            return .failure(.invalidId(reason: "no active lease with this acquisitionId"))
        }
        if s.scope == .foreground { return .success(s) }
        if !pidAlive(s.pid) {
            byId.removeValue(forKey: s.id); removeCursorsLocked(sessionID: s.id)
            return .failure(.invalidId(reason: "the target app exited; acquire again"))
        }
        if s.bid != "?", let now = currentBid(s.pid), now != s.bid {
            byId.removeValue(forKey: s.id); removeCursorsLocked(sessionID: s.id)
            return .failure(.invalidId(reason: "the pid now belongs to a different app; acquire again"))
        }
        return .success(s)
    }

    func release(id: String) -> Result<Void, LeaseError> {
        lock.lock(); defer { lock.unlock() }
        guard let s = byId[id.lowercased()] else {
            return .failure(.invalidId(reason: "no active lease with this acquisitionId"))
        }
        byId.removeValue(forKey: s.id)
        removeCursorsLocked(sessionID: s.id)
        return .success(())
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        if let s = byId.removeValue(forKey: id) { removeCursorsLocked(sessionID: s.id) }
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
        for s in victims {
            byId.removeValue(forKey: s.id)
            removeCursorsLocked(sessionID: s.id)
        }
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
            if !pidAlive(s.pid) {
                byId.removeValue(forKey: s.id); removeCursorsLocked(sessionID: s.id); continue
            }
            if s.bid != "?", let now = currentBid(s.pid), now != s.bid {
                byId.removeValue(forKey: s.id); removeCursorsLocked(sessionID: s.id); continue
            }
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
        return byId[id.lowercased()]
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
