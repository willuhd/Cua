//
//  StreamSettings.swift
//  dz
//
//  The knobs a session is pinned to. dz does not adapt: a session runs at the
//  bitrate, frame rate and resolution it was told to run at, and keeps running
//  there. When the link changes, the user changes the settings.
//

import Foundation

/// How the host places the pointer for this session.
enum PointerMode: String, Codable, CaseIterable {
    /// Captured inside the session window, for games and drag-heavy work.
    case locked
    /// Follows the real pointer and may leave the window.
    case free
}

/// What the encoder is told to do with its bitrate.
enum RateControl: String, Codable, CaseIterable {
    /// Constant bitrate. Needs low delay prediction; the encoder refuses it
    /// for random access streams.
    case cbr
    /// Variable bitrate with a ceiling.
    case vbr
}

/// Everything that defines a stream, in one value that can be diffed, logged
/// and sent to the peer.
struct StreamSettings: Codable, Equatable {
    var width: Int = 1920
    var height: Int = 1080
    var frameRate: Int = 60

    /// Bits per second the encoder is pinned to.
    var bitrate: Int = 6_000_000
    /// SVT-AV1 preset, 0 (slowest, best) through 13 (fastest).
    var preset: Int = 10
    var rateControl: RateControl = .cbr

    /// Fraction of the stream spent on parity, 0...1. Fixed, not adaptive:
    /// size it for the link you expect and leave it.
    var fecOverhead: Double = 0.2
    /// Frames the client may buffer before it starts dropping. Higher absorbs
    /// jitter at the cost of input latency.
    var jitterFrames: Int = 3

    var pointer: PointerMode = .free

    /// Encoder needs low delay prediction for CBR; random access is refused.
    var lowDelay: Bool { true }

    /// Sanity clamp so a bad config fails here rather than inside the encoder.
    func validated() throws -> StreamSettings {
        var s = self
        s.width = max(16, min(width, 7_680))
        s.height = max(16, min(height, 4_320))
        s.frameRate = max(1, min(frameRate, 240))
        s.bitrate = max(100_000, min(bitrate, 200_000_000))
        s.preset = max(0, min(preset, 13))
        s.fecOverhead = max(0, min(fecOverhead, 1))
        s.jitterFrames = max(1, min(jitterFrames, 30))
        // AV1 encodes 4:2:0, so both axes must be even.
        s.width -= s.width % 2
        s.height -= s.height % 2
        return s
    }

    /// What the encoder is pinned to, as a stable summary for logs and the UI.
    var summary: String {
        let mbps = String(format: "%.1f", Double(bitrate) / 1_000_000)
        return "\(width)x\(height)@\(frameRate) \(mbps) Mbps AV1 preset \(preset) \(rateControl.rawValue.uppercased()) FEC \(Int(fecOverhead * 100))% buffer \(jitterFrames)f"
    }
}
