//
//  Session.swift
//  dz
//
//  The two roles, each binding the pieces into something that runs.
//
//  Host: capture -> convert -> encode -> fragment -> UDP, with input arriving
//  on the control channel and injected locally.
//  Client: UDP -> reassemble -> decode -> draw, with input captured in the view
//  and sent back over the control channel.
//
//  Encoding runs on its own serial queue rather than in the capture callback.
//  The capture queue is shallow on purpose, so letting the encoder block it
//  drops frames, which is the right behaviour when we are behind: fewer, newer
//  frames beat a growing backlog.
//

import Foundation
import AppKit

// MARK: - Host

final class HostSession {
    private let settings: StreamSettings
    private let videoPort: UInt16
    private let controlPort: UInt16

    private let source: ScreenSource
    private let converter: I420Converter
    private let encoder: AV1Encoder
    private let sender: VideoSender
    private let injector: InputInjector

    private var control: ControlChannel?
    private let encodeQueue = DispatchQueue(label: "dz.encode", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "dz.control.accept", qos: .userInteractive)
    private var frameIndex: UInt32 = 0
    private var running = false
    private let stateLock = NSLock()

    /// Reported to the UI: frames sent, packets sent, encode failures.
    private(set) var framesSent = 0
    private(set) var packetsSent = 0
    var onInput: ((InputEvent) -> Void)?

    init(settings: StreamSettings,
         videoPort: UInt16 = 47900,
         controlPort: UInt16 = 47901) throws {
        self.settings = try settings.validated()
        self.videoPort = videoPort
        self.controlPort = controlPort
        self.source = ScreenSource(settings: self.settings)
        self.converter = try I420Converter()
        self.encoder = try AV1Encoder(settings: self.settings)
        self.sender = try VideoSender(host: "127.0.0.1", port: videoPort)
        self.injector = InputInjector()
    }

    func start() async throws {
        let channel = try ControlChannel.listen(port: controlPort)
        control = channel
        channel.onEvent = { [weak self] event in
            guard let self else { return }
            self.injector.inject(event)
            self.onInput?(event)
        }
        controlQueue.async {
            do { try channel.acceptAndRead() } catch { NSLog("dz: control channel ended: %@", "\(error)") }
        }

        source.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.encodeQueue.async { self.pipeline(buffer) }
        }
        source.onError = { error in NSLog("dz: capture error: %@", "\(error)") }
        try await source.start()
        stateLock.lock(); running = true; stateLock.unlock()
    }

    private func pipeline(_ buffer: CVPixelBuffer) {
        do {
            let converted = try converter.convert(buffer)
            guard let frame = I420Frame(converted) else { return }
            defer { frame.unlock() }

            let packets = try encoder.encode(frame: frame)
            let interval: Int = max(1, settings.frameRate * 2)
            let keyframe: Bool = (framesSent % interval) == 0
            let stamp: UInt64 = DispatchTime.now().uptimeNanoseconds / 1000
            for packet in packets {
                let fragments: [VideoPacket] = VideoFragmenter.fragments(for: packet,
                                                                         frameIndex: frameIndex,
                                                                         timestampMicros: stamp,
                                                                         keyframe: keyframe,
                                                                         mtu: VideoPacket.defaultMTU)
                sender.send(fragments)
                stateLock.lock(); packetsSent += fragments.count; stateLock.unlock()
            }
            frameIndex &+= 1
            stateLock.lock(); framesSent += 1; stateLock.unlock()
        } catch {
            NSLog("dz: encode failed: %@", "\(error)")
        }
    }

    func stop() {
        source.stop()
        control?.close()
        stateLock.lock(); running = false; stateLock.unlock()
    }
}

// MARK: - Client

final class ClientSession {
    private let settings: StreamSettings
    private let decoder: AV1Decoder
    private let receiver: VideoReceiver
    private let assembler: FrameAssembler
    private let control: ControlChannel
    private let receiveQueue = DispatchQueue(label: "dz.receive", qos: .userInteractive)

    let view: StreamView
    private var running = false
    private let stateLock = NSLock()

    private(set) var framesShown = 0
    private(set) var framesDropped = 0

    /// Must be constructed on the main thread: the view is AppKit.
    init(settings: StreamSettings,
         host: String,
         videoPort: UInt16 = 47900,
         controlPort: UInt16 = 47901) throws {
        self.settings = try settings.validated()
        self.decoder = try AV1Decoder()
        self.receiver = try VideoReceiver(port: videoPort)
        self.assembler = FrameAssembler()
        self.control = try ControlChannel(host: host, port: controlPort)
        self.view = StreamView(frame: NSRect(x: 0, y: 0, width: settings.width, height: settings.height))

        view.pointerCapture = settings.pointer == .locked ? .locked : .free
        view.onInput = { [weak control] event in
            _ = control?.send(event)
        }
    }

    func start() {
        stateLock.lock(); running = true; stateLock.unlock()
        receiveQueue.async { [weak self] in self?.receiveLoop() }
    }

    private func receiveLoop() {
        while true {
            stateLock.lock(); let alive = running; stateLock.unlock()
            guard alive else { break }
            guard let packet = receiver.receive(timeout: 0.2) else { continue }
            guard let whole = assembler.ingest(packet) else { continue }
            do {
                if try decoder.decode(whole) != nil {
                    stateLock.lock(); framesShown += 1; stateLock.unlock()
                }
            } catch {
                stateLock.lock(); framesDropped += 1; stateLock.unlock()
            }
        }
    }

    func stop() {
        stateLock.lock(); running = false; stateLock.unlock()
        control.close()
    }
}
