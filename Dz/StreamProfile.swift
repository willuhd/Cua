//
//  StreamProfile.swift
//  dz
//
//  The stream settings the user pinned, kept between launches.
//
//  This is the only place a session gets its numbers from, so the UI, the host
//  and the client cannot disagree about what the profile is.
//

import Foundation

enum StreamProfile {
    private static let key = "dz.stream.profile"

    /// The profile to start from, falling back to the default on a fresh launch.
    static func load() -> StreamSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(StreamSettings.self, from: data) else {
            return defaults
        }
        return settings
    }

    @discardableResult
    static func save(_ settings: StreamSettings) -> StreamSettings {
        let clean = (try? settings.validated()) ?? defaults
        if let data = try? JSONEncoder().encode(clean) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return clean
    }

    /// Chosen for the Intel client on a constrained link. Pinned, never adjusted.
    static var defaults: StreamSettings {
        var s = StreamSettings()
        s.width = 1920
        s.height = 1080
        s.frameRate = 75
        s.bitrate = 8_000_000
        s.preset = 10
        s.rateControl = .cbr
        s.fecOverhead = 0.2
        s.jitterFrames = 3
        s.pointer = .free
        return s
    }

    /// What the UI renders into the Settings tab.
    static func json(_ settings: StreamSettings) -> [String: Any] {
        [
            "width": settings.width,
            "height": settings.height,
            "frameRate": settings.frameRate,
            "bitrate": settings.bitrate,
            "preset": settings.preset,
            "rateControl": settings.rateControl.rawValue,
            "fecOverhead": settings.fecOverhead,
            "jitterFrames": settings.jitterFrames,
            "pointer": settings.pointer.rawValue,
        ]
    }

    /// Applies a dictionary from the UI on top of the current profile.
    static func apply(_ body: [String: Any], to settings: StreamSettings) -> StreamSettings {
        var s = settings
        func int(_ key: String) -> Int? {
            if let v = body[key] as? Int { return v }
            if let v = body[key] as? Double { return Int(exactly: v) }
            if let v = body[key] as? String { return Int(v) }
            return nil
        }
        if let v = int("width") { s.width = v }
        if let v = int("height") { s.height = v }
        if let v = int("frameRate") { s.frameRate = v }
        if let v = int("bitrate") { s.bitrate = v }
        if let v = int("preset") { s.preset = v }
        if let v = int("jitterFrames") { s.jitterFrames = v }
        if let v = body["rateControl"] as? String, let rc = RateControl(rawValue: v) { s.rateControl = rc }
        if let v = body["pointer"] as? String, let p = PointerMode(rawValue: v) { s.pointer = p }
        if let v = body["fecOverhead"] as? Double { s.fecOverhead = v }
        if let v = body["fecOverhead"] as? String, let d = Double(v) { s.fecOverhead = d }
        return s
    }
}
