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
    private let videoPort: UInt16
    private let controlPort: UInt16
    private let displays: [HostDisplay]
    private let displayID: CGDirectDisplayID

    private var settings: StreamSettings
    private var source: ScreenSource?
    private var encoder: AV1Encoder?
    private var configured = false
    private var configurationError: String?
    private var captureGeneration: UInt64 = 0

    private let converter: I420Converter
    private let injector: InputInjector
    private var sender: VideoSender?
    private let senderLock = NSLock()
    private var control: ControlChannel?

    private let clipboard = ClipboardSync()
    private let encodeQueue = DispatchQueue(label: "dz.encode", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "dz.control.accept", qos: .userInteractive)
    private var frameIndex: UInt32 = 0
    private var running = false
    private let stateLock = NSLock()

    private(set) var framesSent = 0
    private(set) var packetsSent = 0
    private(set) var bytesSent = 0
    private(set) var framesSkipped = 0
    private(set) var measuredFps: Double = 0
    var onInput: ((InputEvent) -> Void)?
    var onStateChange: (() -> Void)?

    private var lastEncodeMicros: UInt64 = 0
    private var windowFrames = 0
    private var statsTimer: DispatchSourceTimer?

    static func availableDisplays() -> [HostDisplay] {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let scale = screen.backingScaleFactor
            let width = max(1, Int((screen.frame.width * scale).rounded()))
            let height = max(1, Int((screen.frame.height * scale).rounded()))
            let name = screen.localizedName.isEmpty ? "Display \(id)" : screen.localizedName
            return HostDisplay(id: id, name: name, width: width, height: height,
                               scale: scale, main: screen == NSScreen.main)
        }
    }

    init(settings: StreamSettings, displayID: CGDirectDisplayID = CGMainDisplayID()) throws {
        self.settings = try settings.validated()
        self.displayID = displayID
        self.displays = Self.availableDisplays()
        self.videoPort = 47900
        self.controlPort = 47901
        self.converter = try I420Converter()
        self.injector = InputInjector()
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    var currentSettings: StreamSettings {
        stateLock.lock(); defer { stateLock.unlock() }
        return settings
    }

    var state: HostSessionState {
        stateLock.lock(); defer { stateLock.unlock() }
        return HostSessionState(hostName: HostName.current(),
                                displays: displays,
                                displayID: displayID,
                                settings: settings,
                                configured: configured,
                                error: configurationError)
    }

    private func currentSender() -> VideoSender? {
        senderLock.lock(); defer { senderLock.unlock() }
        return sender
    }

    func start() async throws {
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
            case .configure(let requested):
                self.acceptConfiguration(requested)
            case .stats, .hostState:
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
                _ = self.control?.send(hostState: self.state)
                NSLog("dz: client connected from %@", peer)
            } catch {
                NSLog("dz: could not open the video path to %@: %@", peer, "\(error)")
            }
        }
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
                self.senderLock.lock(); self.sender = nil; self.senderLock.unlock()
                NSLog("dz: client disconnected")
            }
        }

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
        onStateChange?()
    }

    /// The client is authoritative. The host only clamps the request to what
    /// the selected display can actually produce.
    private func acceptConfiguration(_ requested: StreamSettings) {
        encodeQueue.async { [weak self] in
            guard let self else { return }
            do {
                let accepted = try self.settingsForDisplay(requested)
                try self.rebuild(with: accepted)
                self.stateLock.lock()
                self.settings = accepted
                self.configured = true
                self.configurationError = nil
                self.stateLock.unlock()
                _ = self.control?.send(hostState: self.state)
                self.onStateChange?()
            } catch {
                self.stateLock.lock(); self.configurationError = String(describing: error); self.stateLock.unlock()
                _ = self.control?.send(hostState: self.state)
                self.onStateChange?()
            }
        }
    }

    private func settingsForDisplay(_ requested: StreamSettings) throws -> StreamSettings {
        var accepted = try requested.validated()
        guard let display = displays.first(where: { $0.id == displayID }) ?? displays.first else {
            throw CaptureError.noDisplay
        }
        let widthScale = Double(accepted.width) / Double(display.width)
        let heightScale = Double(accepted.height) / Double(display.height)
        let scale = max(widthScale, heightScale)
        if scale > 1 {
            accepted.width = max(16, Int((Double(accepted.width) / scale).rounded(.down)))
            accepted.height = max(16, Int((Double(accepted.height) / scale).rounded(.down)))
            accepted.width -= accepted.width % 2
            accepted.height -= accepted.height % 2
        }
        return accepted
    }

    private func rebuild(with accepted: StreamSettings) throws {
        stateLock.lock(); captureGeneration &+= 1; let generation = captureGeneration; stateLock.unlock()
        source?.stop()
        source = nil
        encoder = nil

        let nextEncoder = try AV1Encoder(settings: accepted)
        let nextSource = ScreenSource(settings: accepted, displayID: displayID)
        encoder = nextEncoder
        source = nextSource
        lastEncodeMicros = 0
        nextSource.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.encodeQueue.async { self.pipeline(buffer, generation: generation) }
        }
        nextSource.onError = { error in
            NSLog("dz: capture error: %@", "\(error)")
        }
        Task { [weak self] in
            do {
                try await nextSource.start()
                guard let self else { return }
                self.stateLock.lock(); let current = self.captureGeneration; self.stateLock.unlock()
                if current != generation { nextSource.stop() }
            } catch {
                guard let self else { return }
                self.stateLock.lock()
                let current = self.captureGeneration
                if current == generation { self.configurationError = String(describing: error) }
                self.stateLock.unlock()
                if current == generation {
                    _ = self.control?.send(hostState: self.state)
                    self.onStateChange?()
                }
            }
        }
    }

    private func pipeline(_ buffer: CVPixelBuffer, generation: UInt64) {
        stateLock.lock()
        let active = configured && captureGeneration == generation
        let currentSettings = settings
        let currentEncoder = encoder
        stateLock.unlock()
        guard active, currentSender() != nil, let currentEncoder else { return }

        let nowMicros = DispatchTime.now().uptimeNanoseconds / 1000
        let interval = UInt64(1_000_000 / max(1, currentSettings.frameRate))
        if lastEncodeMicros != 0, nowMicros &- lastEncodeMicros < interval {
            stateLock.lock(); framesSkipped += 1; stateLock.unlock()
            return
        }
        lastEncodeMicros = nowMicros
        do {
            let converted = try converter.convert(buffer)
            guard let frame = I420Frame(converted) else { return }
            defer { frame.unlock() }

            let packets = try currentEncoder.encode(frame: frame)
            let keyframeInterval = max(1, currentSettings.frameRate * 2)
            let keyframe = (framesSent % keyframeInterval) == 0
            let stamp = DispatchTime.now().uptimeNanoseconds / 1000
            for packet in packets {
                let fragments = VideoFragmenter.fragments(for: packet,
                                                          frameIndex: frameIndex,
                                                          timestampMicros: stamp,
                                                          keyframe: keyframe,
                                                          mtu: VideoPacket.defaultMTU,
                                                          parityOverhead: currentSettings.fecOverhead)
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
        stateLock.lock(); running = false; stateLock.unlock()
        clipboard.stop()
        statsTimer?.cancel()
        statsTimer = nil
        encodeQueue.sync {
            source?.stop()
            source = nil
            encoder = nil
        }
        control?.close()
    }
}

// MARK: - Client

final class ClientSession {
    private var requestedSettings: StreamSettings
    private var effectiveSettings: StreamSettings?
    private let decoder: AV1Decoder
    private let receiver: VideoReceiver
    private var assembler: FrameAssembler
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
    private(set) var hostStats: SessionStats?
    private(set) var hostState: HostSessionState?
    var onStateChange: (() -> Void)?

    var currentSettings: StreamSettings {
        stateLock.lock(); defer { stateLock.unlock() }
        return effectiveSettings ?? requestedSettings
    }

    /// Must be constructed on the main thread: the view is AppKit.
    init(settings: StreamSettings,
         host: String,
         videoPort: UInt16 = 47900,
         controlPort: UInt16 = 47901) throws {
        self.requestedSettings = try settings.validated()
        self.decoder = try AV1Decoder()
        self.receiver = try VideoReceiver(port: videoPort)
        self.assembler = FrameAssembler(maxAgeSeconds: Self.age(for: self.requestedSettings))
        self.control = try ControlChannel(host: host, port: controlPort)
        self.view = StreamView(frame: NSRect(x: 0, y: 0, width: self.requestedSettings.width,
                                             height: self.requestedSettings.height))

        view.pointerCapture = self.requestedSettings.pointer == .locked ? .locked : .free
        view.onInput = { [weak control] event in
            _ = control?.send(event)
        }
        control.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .stats(let stats):
                self.stateLock.lock(); self.hostStats = stats; self.stateLock.unlock()
                self.notifyChanged()
            case .hostState(let state):
                self.acceptHostState(state)
            case .clipboard(let payload):
                self.clipboard.apply(payload)
            case .input, .configure:
                break
            }
        }
        clipboard.onCopy = { [weak control] payload in
            _ = control?.send(clipboard: payload)
        }
        clipboard.start()
        control.startReading()
    }

    private static func age(for settings: StreamSettings) -> Double {
        max(0.25, Double(settings.jitterFrames) / Double(max(1, settings.frameRate)) * 2)
    }

    private func notifyChanged() {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
    }

    private func acceptHostState(_ state: HostSessionState) {
        stateLock.lock()
        let changedSize = effectiveSettings?.width != state.settings.width
            || effectiveSettings?.height != state.settings.height
        hostState = state
        effectiveSettings = state.settings
        stateLock.unlock()
        if changedSize {
            receiveQueue.async { [weak self] in
                self?.assembler = FrameAssembler(maxAgeSeconds: Self.age(for: state.settings))
            }
        }
        let pointer = state.settings.pointer
        DispatchQueue.main.async { [weak view] in
            view?.pointerCapture = pointer == .locked ? .locked : .free
        }
        if let error = state.error {
            DispatchQueue.main.async { [weak view] in view?.setStatus(error) }
        }
        notifyChanged()
    }

    /// Sends a new profile to the host. The host replies with hostState once
    /// capture and the encoder have actually been rebuilt.
    func requestSettings(_ settings: StreamSettings) {
        do {
            let clean = try settings.validated()
            stateLock.lock(); requestedSettings = clean; stateLock.unlock()
            let pointer = clean.pointer
            DispatchQueue.main.async { [weak view] in
                view?.pointerCapture = pointer == .locked ? .locked : .free
            }
            receiveQueue.async { [weak self] in
                self?.assembler = FrameAssembler(maxAgeSeconds: Self.age(for: clean))
            }
            _ = control.send(configure: clean)
        } catch {
            DispatchQueue.main.async { [weak view] in view?.setStatus(String(describing: error)) }
        }
    }

    func start() {
        view.setStatus("Connecting...")
        stateLock.lock(); running = true; loopRunning = true; stateLock.unlock()
        _ = control.send(configure: requestedSettings)
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
                assembler.expireStale()
                continue
            }
            stateLock.lock(); packetsReceived += 1; stateLock.unlock()
            guard let whole = assembler.ingest(packet) else { continue }
            do {
                guard let frame = try decoder.decode(whole) else { continue }
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
        if wasRunning { _ = loopFinished.wait(timeout: .now() + 2) }
    }
}
