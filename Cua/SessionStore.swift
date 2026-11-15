import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – session store (in-memory only: leases + cursors)
struct Session {
    var id: String
    var pid: Int32
    var agentLabel: String?
    var appName: String
    var bid: String
}
final class SessionStore {
    static let shared = SessionStore()
    private var lock = NSLock()
    private var byPid: [Int32: Session] = [:]
    private var cursors: [String: (Double, Double)] = [:]  // "pid:wid" -> pos, plus "last"
    enum LeaseError: Error {
        case held(Session)
        case invalidId(reason: String)
        case unknownApp(String)
    }
    func makeShortId() -> String { String(UUID().uuidString.prefix(8).lowercased()) }
    func acquire(pid: Int32, agentLabel: String?) -> Result<Session, LeaseError> {
        lock.lock(); defer { lock.unlock() }
        if let existing = byPid[pid] { return .failure(.held(existing)) }
        let name = appNameForPid(pid)
        let bid = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })?.bundleIdentifier ?? "?"
        let s = Session(id: makeShortId(), pid: pid, agentLabel: agentLabel, appName: name, bid: bid)
        byPid[pid] = s
        return .success(s)
    }
    func release(pid: Int32, id: String) -> Result<Void, LeaseError> {
        lock.lock(); defer { lock.unlock() }
        guard let s = byPid[pid] else { return .failure(.invalidId(reason: "no agent owns this app — register it first")) }
        guard s.id.lowercased() == id.lowercased() else { return .failure(.invalidId(reason: "invalid acquisition id")) }
        byPid.removeValue(forKey: pid)
        return .success(())
    }
    /// Free from UI (user action). Just drops the session; next acquire rotates to a fresh ID.
    func free(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        byPid.removeValue(forKey: pid)
    }
    func validate(pid: Int32, id: String) -> Result<Session, LeaseError> {
        lock.lock(); defer { lock.unlock() }
        guard let s = byPid[pid] else { return .failure(.invalidId(reason: "no agent owns this app — register it first (acquire)")) }
        guard s.id.lowercased() == id.lowercased() else { return .failure(.invalidId(reason: "invalid acquisition id")) }
        return .success(s)
    }
    func sessions() -> [Session] {
        lock.lock(); defer { lock.unlock() }
        return Array(byPid.values).sorted { $0.appName < $1.appName }
    }
    func saveCursor(pid: Int32, wid: UInt32, x: Double, y: Double) {
        lock.lock(); defer { lock.unlock() }
        cursors["\(pid):\(wid)"] = (x, y)
        cursors["last"] = (x, y)
    }
    func lastCursor() -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        return cursors["last"]
    }
    func cursor(pid: Int32, wid: UInt32) -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        return cursors["\(pid):\(wid)"]
    }
}

