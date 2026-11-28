//
//  RemoteHosts.swift
//  dz
//
//  Saved hosts and their profiles. A host is an address plus a name the user
//  chose, and it owns one profile. The same address may appear more than once
//  under different names, which is how a fast-network profile and a hotel
//  profile coexist without one overwriting the other.
//

import Foundation

struct SavedHost: Codable, Equatable, Identifiable {
    var id: String
    var alias: String
    var address: String
    var profileName: String
    var settings: StreamSettings
    var lastUsed: Date?

    init(id: String = String(UUID().uuidString.prefix(8).lowercased()),
         alias: String,
         address: String,
         profileName: String = "Default",
         settings: StreamSettings = StreamProfile.defaults,
         lastUsed: Date? = nil) {
        self.id = id
        self.alias = alias
        self.address = Self.normalizedAddress(address)
        self.profileName = profileName
        self.settings = (try? settings.validated()) ?? StreamProfile.defaults
        self.lastUsed = lastUsed
    }

    static func normalizedAddress(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let host = url.host {
            value = host
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var json: [String: Any] {
        var out = StreamProfile.json(settings)
        out["id"] = id
        out["alias"] = alias
        out["address"] = address
        out["profileName"] = profileName
        out["settings"] = StreamProfile.json(settings)
        if let lastUsed { out["lastUsed"] = Int(lastUsed.timeIntervalSince1970 * 1000) }
        return out
    }
}

final class HostStore {
    static let shared = HostStore()
    private let key = "dz.remote.hosts"
    private let lock = NSLock()
    private var cached: [SavedHost]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let hosts = try? JSONDecoder().decode([SavedHost].self, from: data) {
            cached = hosts
        } else {
            cached = []
        }
    }

    func all() -> [SavedHost] {
        lock.lock(); defer { lock.unlock() }
        return cached.sorted {
            if $0.lastUsed != $1.lastUsed { return ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            return $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
    }

    func find(_ id: String) -> SavedHost? {
        lock.lock(); defer { lock.unlock() }
        return cached.first { $0.id == id }
    }

    @discardableResult
    func add(alias: String, address: String, profileName: String, settings: StreamSettings) -> SavedHost {
        let host = SavedHost(alias: alias, address: address, profileName: profileName, settings: settings)
        lock.lock(); cached.append(host); saveLocked(); lock.unlock()
        return host
    }

    @discardableResult
    func update(_ host: SavedHost) -> SavedHost {
        var clean = host
        clean.address = SavedHost.normalizedAddress(clean.address)
        clean.settings = (try? clean.settings.validated()) ?? StreamProfile.defaults
        lock.lock()
        if let index = cached.firstIndex(where: { $0.id == clean.id }) {
            cached[index] = clean
        } else {
            cached.append(clean)
        }
        saveLocked()
        lock.unlock()
        return clean
    }

    func delete(_ id: String) {
        lock.lock(); cached.removeAll { $0.id == id }; saveLocked(); lock.unlock()
    }

    func touch(_ id: String) {
        lock.lock()
        if let index = cached.firstIndex(where: { $0.id == id }) {
            cached[index].lastUsed = Date()
            saveLocked()
        }
        lock.unlock()
    }

    var json: [[String: Any]] { all().map { $0.json } }

    private func saveLocked() {
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
