//
//  SelfTest.swift
//  dz
//
//  Exercises everything that can be exercised without a second machine:
//  encode, wire format, UDP, FEC recovery, decode, colour fidelity through the
//  display converter, and the control channel.
//
//      dz.app/Contents/MacOS/dz --selftest
//
//  Two things are deliberately outside this: screen capture and drawing to a
//  window. Both need a user grant or a visible screen, and both are reported by
//  --capture-check instead.
//

import Foundation
import CoreVideo
import VideoToolbox
import Metal
import MetalKit

enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        say("dz self test")

        if !pipelineTest() { failures += 1 }
        if !colourTest() { failures += 1 }
        if !controlTest() { failures += 1 }
        if !renderTest() { failures += 1 }

        say(failures == 0 ? "PASS" : "FAIL: " + String(failures) + " check(s) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: - transport and codec

    private static func pipelineTest() -> Bool {
        var settings = StreamSettings()
        settings.width = 640
        settings.height = 360
        settings.frameRate = 60
        settings.bitrate = 2_000_000
        settings.preset = 10
        let frames = 30
        let port: UInt16 = 47_199
        say("profile: " + settings.summary)

        do {
            settings = try settings.validated()
            let encoder = try AV1Encoder(settings: settings)
            let decoder = try AV1Decoder()
            let sender = try VideoSender(host: "127.0.0.1", port: port)
            let receiver = try VideoReceiver(port: port)
            let assembler = FrameAssembler(maxAgeSeconds: 2)

            let w = settings.width
            let h = settings.height
            let lumaBytes = w * h
            let chromaBytes = (w / 2) * (h / 2)
            var frame = [UInt8](repeating: 0, count: lumaBytes + chromaBytes * 2)
            var packets = 0
            var index: UInt32 = 0

            for f in 0..<frames {
                for y in 0..<h {
                    for x in 0..<w { frame[y * w + x] = UInt8((x + y + f * 4) & 0xFF) }
                }
                for i in 0..<(chromaBytes * 2) { frame[lumaBytes + i] = 128 }
                for (offset, packet) in try encodeFrame(encoder, frame, index: index,
                                                        keyframe: index % 60 == 0,
                                                        parity: settings.fecOverhead,
                                                        sender: sender) {
                    packets += 1
                    index = index &+ 1
                    _ = offset
                    _ = packet
                }
            }
            for packet in try encoder.finish() {
                for part in VideoFragmenter.fragments(for: packet, frameIndex: index,
                                                      timestampMicros: UInt64(index) * 16666,
                                                      keyframe: false, mtu: VideoPacket.defaultMTU,
                                                      parityOverhead: settings.fecOverhead) {
                    sender.send(part)
                }
                packets += 1
                index = index &+ 1
            }

            var framesOut = 0
            var discarded = 0
            var deadline = Date().addingTimeInterval(5)
            while framesOut < packets {
                guard let packet = receiver.receive(timeout: 0.2) else {
                    assembler.expireStale()
                    if Date() > deadline { break }
                    continue
                }
                if !packet.isParity, packet.fragmentIndex == 0, packet.frameIndex % 3 == 0 {
                    discarded += 1
                    continue
                }
                guard let whole = assembler.ingest(packet) else { continue }
                if try decoder.decode(whole) != nil {
                    framesOut += 1
                    deadline = Date().addingTimeInterval(5)
                }
            }

            say("  transport: " + String(packets) + " frames, dropped " + String(discarded)
                + " fragments, recovered " + String(assembler.recovered)
                + ", decoded " + String(framesOut))
            if assembler.recovered == 0 { say("  FAIL: parity never used"); return false }
            if framesOut != packets { say("  FAIL: frames lost"); return false }
            return true
        } catch {
            say("  FAIL: " + String(describing: error))
            return false
        }
    }

    private static func encodeFrame(_ encoder: AV1Encoder, _ frame: [UInt8], index: UInt32,
                                    keyframe: Bool, parity: Double,
                                    sender: VideoSender) throws -> [(Int, Data)] {
        var scratch = frame
        let encoded = try scratch.withUnsafeMutableBytes { raw -> [Data] in
            try encoder.encode(i420: raw.baseAddress!)
        }
        var out: [(Int, Data)] = []
        for (offset, packet) in encoded.enumerated() {
            let parts = VideoFragmenter.fragments(for: packet, frameIndex: index,
                                                  timestampMicros: UInt64(index) * 16666,
                                                  keyframe: keyframe,
                                                  mtu: VideoPacket.defaultMTU,
                                                  parityOverhead: parity)
            sender.send(parts)
            out.append((offset, packet))
        }
        return out
    }

    // MARK: - colour

    /// A known colour has to survive encode, decode and the converter that
    /// feeds the renderer. This is the check that catches a valid bitstream
    /// carrying the wrong picture.
    private static func colourTest() -> Bool {
        do {
            var settings = StreamSettings()
            settings.width = 320
            settings.height = 240
            settings.frameRate = 30
            settings.bitrate = 1_000_000
            settings.preset = 10
            settings = try settings.validated()

            let encoder = try AV1Encoder(settings: settings)
            let decoder = try AV1Decoder()
            let display = try DisplayConverter()

            let w = settings.width
            let h = settings.height
            let lumaBytes = w * h
            let chromaBytes = (w / 2) * (h / 2)
            // Video-range red, the values measured out of the capture converter.
            var frame = [UInt8](repeating: 63, count: lumaBytes)
            frame += [UInt8](repeating: 102, count: chromaBytes)
            frame += [UInt8](repeating: 240, count: chromaBytes)

            var packets: [Data] = []
            for _ in 0..<6 {
                packets += try frame.withUnsafeMutableBytes { raw -> [Data] in
                    try encoder.encode(i420: raw.baseAddress!)
                }
            }
            packets += try encoder.finish()
            guard !packets.isEmpty else { say("  FAIL: nothing encoded"); return false }

            var last: CVPixelBuffer?
            for packet in packets {
                if let decoded = try decoder.decode(packet) { last = decoded }
            }
            guard let decoded = last else { say("  FAIL: nothing decoded"); return false }

            let bgra = try display.convert(decoded)
            CVPixelBufferLockBaseAddress(bgra, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(bgra) else {
                say("  FAIL: no pixels"); return false
            }
            let stride = CVPixelBufferGetBytesPerRow(bgra)
            let mid = (h / 2) * stride + (w / 2) * 4
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            let b = Int(pixels[mid]), g = Int(pixels[mid + 1]), r = Int(pixels[mid + 2])
            say("  colour: centre pixel RGB(" + String(r) + ", " + String(g) + ", " + String(b) + ")")
            guard r > 180, g < 90, b < 90 else {
                say("  FAIL: red did not survive the round trip")
                return false
            }
            return true
        } catch {
            say("  FAIL: " + String(describing: error))
            return false
        }
    }

    // MARK: - control channel

    private static func controlTest() -> Bool {
        let port: UInt16 = 47_198
        do {
            let host = try ControlChannel.listen(port: port)
            let ready = DispatchSemaphore(value: 0)
            var receivedInput = false
            var receivedStats = false
            host.onMessage = { message in
                switch message {
                case .input(let event): receivedInput = event.code == 42 && event.kind == .keyDown
                case .stats(let stats): receivedStats = stats.targetFps == 75
                case .clipboard: break
                }
            }
            DispatchQueue.global().async {
                ready.signal()
                try? host.acceptAndRead()
            }
            ready.wait()
            Thread.sleep(forTimeInterval: 0.2)

            let client = try ControlChannel(host: "127.0.0.1", port: port)
            var event = InputEvent(kind: .keyDown)
            event.code = 42
            _ = client.send(event)
            var stats = SessionStats(role: "host", fps: 60, framesSent: 1, packetsSent: 2,
                                     bytesSent: 3, framesSkipped: 0, targetFps: 75, timestampMicros: 0)
            stats.targetFps = 75
            _ = client.send(stats: stats)

            var waited = 0.0
            while waited < 2.0 && !(receivedInput && receivedStats) {
                Thread.sleep(forTimeInterval: 0.05)
                waited += 0.05
            }
            client.close()
            host.close()
            say("  control: input " + (receivedInput ? "ok" : "MISSING")
                + ", stats " + (receivedStats ? "ok" : "MISSING"))
            return receivedInput && receivedStats
        } catch {
            say("  FAIL: control channel: " + String(describing: error))
            return false
        }
    }

    // MARK: - capture

    /// Whether screen capture can run at all on this machine, and what it does
    /// when it tries. Exit 0 captured frames, 2 no permission, 1 error.
    static func captureCheck() -> Int32 {
        say("capture check")
        let trusted = CGPreflightScreenCaptureAccess()
        say("  Screen Recording: " + (trusted ? "granted" : "NOT granted"))
        guard trusted else {
            say("  capture cannot be tested until this app is granted Screen Recording")
            return 2
        }

        var settings = StreamSettings()
        settings.width = 640
        settings.height = 360
        settings.frameRate = 30
        let source = ScreenSource(settings: settings)
        let got = DispatchSemaphore(value: 0)
        var frames = 0
        var firstSize = ""
        source.onFrame = { buffer in
            frames += 1
            if frames == 1 {
                firstSize = String(CVPixelBufferGetWidth(buffer)) + "x" + String(CVPixelBufferGetHeight(buffer))
            }
            got.signal()
        }
        source.onError = { error in say("  capture error: " + String(describing: error)) }

        let started = DispatchSemaphore(value: 0)
        Task {
            do { try await source.start() } catch {
                say("  start failed: " + String(describing: error))
                started.signal()
                return
            }
            started.signal()
        }
        _ = started.wait(timeout: .now() + 10)

        var captured = 0
        while captured < 3, got.wait(timeout: .now() + 3) == .success {
            captured += 1
        }
        source.stop()
        say("  captured " + String(captured) + " frames, first " + (firstSize.isEmpty ? "none" : firstSize))
        return captured > 0 ? 0 : 1
    }

    // MARK: - render

    /// Compiles the window's shader and runs it offscreen, so the drawing path
    /// is proven without a window. The only thing left untested after this is
    /// whether a window appears on a screen.
    private static func renderTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            say("  FAIL: no Metal device")
            return false
        }
        do {
            let library = try device.makeLibrary(source: StreamShaders.source, options: nil)
            guard let vertexFn = library.makeFunction(name: "vertex_main"),
                  let fragmentFn = library.makeFunction(name: "fragment_main") else {
                say("  FAIL: shader functions missing")
                return false
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            let size = 64
            let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: size, height: size,
                                                                  mipmapped: false)
            target.usage = [.renderTarget, .shaderRead]
            target.storageMode = .managed
            guard let targetTexture = device.makeTexture(descriptor: target) else {
                say("  FAIL: no render target")
                return false
            }

            // A red source buffer, exactly as the decoder would hand over.
            var source: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                             kCVPixelBufferMetalCompatibilityKey as String: true]
            guard CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                      kCVPixelFormatType_32BGRA,
                                      attributes as CFDictionary, &source) == kCVReturnSuccess,
                  let source else {
                say("  FAIL: no source buffer")
                return false
            }
            CVPixelBufferLockBaseAddress(source, [])
            let rowBytes = CVPixelBufferGetBytesPerRow(source)
            let pixels = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<size {
                for x in 0..<size {
                    let p = y * rowBytes + x * 4
                    pixels[p] = 0; pixels[p + 1] = 0; pixels[p + 2] = 255; pixels[p + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(source, [])

            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            guard let cache else { say("  FAIL: no texture cache"); return false }
            var reference: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, source, nil,
                                                      .bgra8Unorm, size, size, 0, &reference)
            guard let reference, let sourceTexture = CVMetalTextureGetTexture(reference) else {
                say("  FAIL: could not wrap the buffer as a texture")
                return false
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = targetTexture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
                say("  FAIL: no encoder")
                return false
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            if let blit = buffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: targetTexture)
                blit.endEncoding()
            }
            buffer.commit()
            buffer.waitUntilCompleted()

            var readback = [UInt8](repeating: 0, count: size * size * 4)
            targetTexture.getBytes(&readback, bytesPerRow: size * 4,
                                   from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            let mid = (size / 2) * size * 4 + (size / 2) * 4
            let b = Int(readback[mid]), g = Int(readback[mid + 1]), r = Int(readback[mid + 2])
            say("  render: centre pixel RGB(" + String(r) + ", " + String(g) + ", " + String(b) + ")")
            guard r > 180, g < 90, b < 90 else {
                say("  FAIL: shader did not draw the source texture")
                return false
            }
            return true
        } catch {
            say("  FAIL: render: " + String(describing: error))
            return false
        }
    }

    private static func say(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
