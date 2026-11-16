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
