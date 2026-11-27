//
//  ScreenSource.swift
//  dz
//
//  Continuous screen capture for the host side.
//
//  Captures a display as bi-planar video-range 4:2:0, which is half the bytes
//  of BGRA and converts to the planar I420 the encoder wants in one GPU pass.
//  Frames arrive on a private queue and are handed straight to the caller; the
//  queue is deliberately shallow, because a deep one buys smoothness by
//  spending latency, and latency is the thing we have least of.
//

import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case notAuthorized
    case stream(String)

    var description: String {
        switch self {
        case .noDisplay: return "no display to capture"
        case .notAuthorized: return "Screen Recording permission is not granted"
        case .stream(let m): return "capture stream failed: \(m)"
        }
    }
}

final class ScreenSource: NSObject, SCStreamOutput {
    /// Called once per captured frame, on the capture queue.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called once per capture error, so the host can surface it in the UI.
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "dz.capture", qos: .userInteractive)
    private let settings: StreamSettings
    private let displayID: CGDirectDisplayID

    init(settings: StreamSettings, displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.settings = settings
        self.displayID = displayID
        super.init()
    }

    /// Starts capture. Throws rather than prompting: the caller decides when to
    /// ask the user for Screen Recording.
    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.notAuthorized }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.stream(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Capture at the size we stream, so nothing is rescaled twice.
        config.width = settings.width
        config.height = settings.height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        config.captureResolution = .best
        config.queueDepth = 3
        // Pin the cadence instead of accepting whatever the display does.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw CaptureError.stream(error.localizedDescription)
        }
        self.stream = stream
    }

    func stop() {
        let running = stream
        stream = nil
        guard let running else { return }
        Task { try? await running.stopCapture() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // .idle means the screen did not change; sending it again would spend
        // bits on a picture the client already has.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}
