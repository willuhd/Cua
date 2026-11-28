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
    /// Created once a client connects, pointed at whatever address it came
    /// from. Written on the accept thread, read on the encode thread.
    private var sender: VideoSender?
    private let senderLock = NSLock()
    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func currentSender() -> VideoSender? {
        senderLock.lock(); defer { senderLock.unlock() }
        return sender
    }
    private let injector: InputInjector

    private var control: ControlChannel?
    private let clipboard = ClipboardSync()
    private let loopFinished = DispatchSemaphore(value: 0)
    private var loopRunning = false
    private let encodeQueue = DispatchQueue(label: "dz.encode", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "dz.control.accept", qos: .userInteractive)
    private var frameIndex: UInt32 = 0
    private var running = false
    private let stateLock = NSLock()

    /// Reported to the UI and broadcast to the client.
    private(set) var framesSent = 0
    private(set) var packetsSent = 0
    private(set) var bytesSent = 0
    private(set) var framesSkipped = 0
    private(set) var measuredFps: Double = 0
    var onInput: ((InputEvent) -> Void)?

    /// Cadence gate: a frame that arrives sooner than the pinned interval is
    /// dropped, never encoded. Capture can deliver faster than the stream rate
    /// (a display changing mode, or ScreenCaptureKit coalescing differently),
    /// and encoding those would burn the host's cores on frames the client
    /// never asked for.
    private var lastEncodeMicros: UInt64 = 0
    private var windowFrames = 0
    private var statsTimer: DispatchSourceTimer?

    init(settings: StreamSettings,
         videoPort: UInt16 = 47900,
         controlPort: UInt16 = 47901) throws {
        self.settings = try settings.validated()
        self.videoPort = videoPort
        self.controlPort = controlPort
        self.source = ScreenSource(settings: self.settings)
        self.converter = try I420Converter()
        self.encoder = try AV1Encoder(settings: self.settings)
        self.injector = InputInjector()
    }

    func start() async throws {
        // Set before anything reads it: the accept loop exits immediately if
        // the session does not consider itself running yet, and then no client
        // is ever accepted.
        stateLock.lock(); running = true; stateLock.unlock()
        let channel = try ControlChannel.listen(port: controlPort)
        control = channel
        channel.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .input(let event):
                self.injector.inject(event)
                self.onInput?(event)
            case .clipboard(let payload):
                self.clipboard.apply(payload)
            case .stats:
                break
            }
        }
        clipboard.onCopy = { [weak self] payload in
            _ = self?.control?.send(clipboard: payload)
        }
        clipboard.start()
        channel.onConnected = { [weak self] peer in
            guard let self else { return }
            do {
                let created = try VideoSender(host: peer, port: self.videoPort)
                self.senderLock.lock(); self.sender = created; self.senderLock.unlock()
                NSLog("dz: client connected from %@", peer)
            } catch {
                NSLog("dz: could not open the video path to %@: %@", peer, "\(error)")
            }
        }
        // The listener stays open, so a client that quits and comes back gets
        // a fresh connection instead of needing the host restarted.
        controlQueue.async { [weak self] in
            while let self, self.isRunning {
                do {
                    try channel.acceptAndRead()
                } catch {
                    if !self.isRunning { break }
                    NSLog("dz: control accept failed: %@", String(describing: error))
                    usleep(200_000)
                    continue
                }
                // The client went away; the next one gets a new video path.
                self.senderLock.lock(); self.sender = nil; self.senderLock.unlock()
                NSLog("dz: client disconnected")
            }
        }

        // Tell the client what this host is really doing, once a second. The
        // timer needs its own queue: controlQueue is occupied by the blocking
        // accept loop for as long as a client is connected, which starved this
        // and left the reported rate at zero.
        let statsQueue = DispatchQueue(label: "dz.stats", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: statsQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let channel = self.control else { return }
            self.stateLock.lock()
            let fps = Double(self.windowFrames)
            self.windowFrames = 0
            self.measuredFps = fps
            let stats = SessionStats(role: "host",
                                     fps: fps,
                                     framesSent: self.framesSent,
                                     packetsSent: self.packetsSent,
                                     bytesSent: self.bytesSent,
                                     framesSkipped: self.framesSkipped,
                                     targetFps: self.settings.frameRate,
                                     timestampMicros: DispatchTime.now().uptimeNanoseconds / 1000)
            self.stateLock.unlock()
            _ = channel.send(stats: stats)
        }
        timer.resume()
        statsTimer = timer

        source.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.encodeQueue.async { self.pipeline(buffer) }
        }
        source.onError = { error in NSLog("dz: capture error: %@", "\(error)") }
        do {
            try await source.start()
        } catch {
            stateLock.lock(); running = false; stateLock.unlock()
            control?.close()
            control = nil
            throw error
        }
    }

    private func pipeline(_ buffer: CVPixelBuffer) {
        guard currentSender() != nil else { return }
        let nowMicros = DispatchTime.now().uptimeNanoseconds / 1000
        let interval = UInt64(1_000_000 / max(1, settings.frameRate))
        if lastEncodeMicros != 0, nowMicros &- lastEncodeMicros < interval {
            stateLock.lock(); framesSkipped += 1; stateLock.unlock()
            return
        }
        lastEncodeMicros = nowMicros
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
                                                                         mtu: VideoPacket.defaultMTU,
                                                                         parityOverhead: settings.fecOverhead)
                currentSender()?.send(fragments)
                let sentBytes = fragments.reduce(0) { $0 + $1.payload.count + VideoPacket.headerSize }
                stateLock.lock()
                packetsSent += fragments.count
                bytesSent += sentBytes
                stateLock.unlock()
            }
            frameIndex &+= 1
            stateLock.lock(); framesSent += 1; windowFrames += 1; stateLock.unlock()
        } catch {
            NSLog("dz: encode failed: %@", "\(error)")
        }
    }

    func stop() {
        // Cleared first so the accept loop stops waiting before its listener
        // is taken away underneath it.
        stateLock.lock(); running = false; stateLock.unlock()
        clipboard.stop()
        statsTimer?.cancel()
        statsTimer = nil
        // A frame may be mid-encode; the encoder must not be released under it.
        encodeQueue.sync { }
        source.stop()
        control?.close()
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
    private let display = try? DisplayConverter()
    private let clipboard = ClipboardSync()
    private let loopFinished = DispatchSemaphore(value: 0)
    private var loopRunning = false

    let view: StreamView
    private var running = false
    private let stateLock = NSLock()

    private(set) var framesShown = 0
    private(set) var framesDropped = 0
    private(set) var packetsReceived = 0
    /// What the host says it is encoding, so the two ends can be compared.
    private(set) var hostStats: SessionStats?

    /// Must be constructed on the main thread: the view is AppKit.
    init(settings: StreamSettings,
         host: String,
         videoPort: UInt16 = 47900,
         controlPort: UInt16 = 47901) throws {
        self.settings = try settings.validated()
        self.decoder = try AV1Decoder()
        self.receiver = try VideoReceiver(port: videoPort)
        // A frame that never completes should be given up on after roughly the
        // buffer the user pinned, not held until memory notices.
        let age = Double(settings.jitterFrames) / Double(max(1, settings.frameRate)) * 2
        self.assembler = FrameAssembler(maxAgeSeconds: max(0.25, age))
        self.control = try ControlChannel(host: host, port: controlPort)
        self.view = StreamView(frame: NSRect(x: 0, y: 0, width: settings.width, height: settings.height))

        view.pointerCapture = settings.pointer == .locked ? .locked : .free
        view.onInput = { [weak control] event in
            _ = control?.send(event)
        }
        control.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .stats(let stats): self.hostStats = stats
            case .clipboard(let payload): self.clipboard.apply(payload)
            case .input: break
            }
        }
        clipboard.onCopy = { [weak control] payload in
            _ = control?.send(clipboard: payload)
        }
        clipboard.start()
        control.startReading()
    }

    func start() {
        view.setStatus("Connecting...")
        stateLock.lock(); running = true; loopRunning = true; stateLock.unlock()
        // If nothing arrives, say so rather than showing an empty window. The
        // usual cause is the other Mac not sharing yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); let shown = self.framesShown; let alive = self.running
            self.stateLock.unlock()
            if alive && shown == 0 {
                self.stateLock.lock(); let packets = self.packetsReceived; self.stateLock.unlock()
                if packets == 0 {
                    self.view.setStatus("No video arriving. Is the other Mac sharing, and is UDP 47900 open?")
                } else {
                    self.view.setStatus("Video arriving (" + String(packets) + " packets) but nothing decoded.")
                }
            }
        }
        receiveQueue.async { [weak self] in
            self?.receiveLoop()
            self?.loopFinished.signal()
        }
    }

    private func receiveLoop() {
        while true {
            stateLock.lock(); let alive = running; stateLock.unlock()
            guard alive else { break }
            guard let packet = receiver.receive(timeout: 0.2) else {
                _ = 0
                // Nothing arriving is exactly when stale frames pile up.
                assembler.expireStale()
                continue
            }
            stateLock.lock(); packetsReceived += 1; stateLock.unlock()
            guard let whole = assembler.ingest(packet) else { continue }
            do {
                guard let frame = try decoder.decode(whole) else { continue }
                // The layer samples BGRA, so the decoded planes are converted
                // once and drawn; the counter only moves when a frame is
                // actually handed to the view.
                if let bgra = try display?.convert(frame) {
                    let view = self.view
                    DispatchQueue.main.async { view.display(bgra) }
                }
                stateLock.lock(); framesShown += 1; stateLock.unlock()
            } catch {
                stateLock.lock(); framesDropped += 1; stateLock.unlock()
            }
        }
    }

    func stop() {
        clipboard.stop()
        stateLock.lock(); running = false; let wasRunning = loopRunning; loopRunning = false
        stateLock.unlock()
        control.close()
        // Wait for the loop to leave before the decoder and the view are
        // released, otherwise a frame is decoded into a freed context.
        if wasRunning { _ = loopFinished.wait(timeout: .now() + 2) }
    }
}
