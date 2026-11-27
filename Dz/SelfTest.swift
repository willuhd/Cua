//
//  SelfTest.swift
//  dz
//
//  Exercises the pipeline without a window, a screen or a second machine.
//
//  Synthetic frames go through the real encoder, the real wire format, real
//  UDP over loopback, the real reassembler and the real decoder. That covers
//  everything except capture and drawing, so a failure here is a genuine
//  failure of the parts that are hardest to debug when a session misbehaves.
//
//      dz.app/Contents/MacOS/dz --selftest
//

import Foundation
import CoreVideo

enum SelfTest {
    static func run() -> Int32 {
        var settings = StreamSettings()
        settings.width = 640
        settings.height = 360
        settings.frameRate = 60
        settings.bitrate = 2_000_000
        settings.preset = 10
        settings.rateControl = .cbr
        let frames = 30
        let port: UInt16 = 47_199

        say("dz self test")
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
            var fragments = 0
            var index: UInt32 = 0

            for f in 0..<frames {
                for y in 0..<h {
                    for x in 0..<w {
                        frame[y * w + x] = UInt8((x + y + f * 4) & 0xFF)
                    }
                }
                for i in 0..<(chromaBytes * 2) { frame[lumaBytes + i] = 128 }

                let encoded = try frame.withUnsafeMutableBytes { raw -> [Data] in
                    try encoder.encode(i420: raw.baseAddress!)
                }
                for packet in encoded {
                    let parts = VideoFragmenter.fragments(for: packet, frameIndex: index,
                                                          timestampMicros: UInt64(index) * 16666,
                                                          keyframe: index % 60 == 0,
                                                          mtu: VideoPacket.defaultMTU)
                    sender.send(parts)
                    packets += 1
                    fragments += parts.count
                    index += 1
                }
            }
            for packet in try encoder.finish() {
                let parts = VideoFragmenter.fragments(for: packet, frameIndex: index,
                                                      timestampMicros: UInt64(index) * 16666,
                                                      keyframe: false, mtu: VideoPacket.defaultMTU)
                sender.send(parts)
                packets += 1
                fragments += parts.count
                index += 1
            }
            say("encoded \(packets) packets into \(fragments) fragments")

            var framesOut = 0
            var received = 0
            while framesOut < packets {
                guard let packet = receiver.receive(timeout: 1.0) else { break }
                received += 1
                guard let whole = assembler.ingest(packet) else { continue }
                if try decoder.decode(whole) != nil { framesOut += 1 }
            }
            say("received \(received) fragments, decoded \(framesOut) of \(packets) frames")

            guard received == fragments else {
                say("FAIL: fragments lost on loopback")
                return 1
            }
            guard framesOut == packets else {
                say("FAIL: \(packets - framesOut) frames did not decode")
                return 1
            }
            say("PASS")
            return 0
        } catch {
            say("FAIL: " + String(describing: error))
            return 1
        }
    }

    private static func say(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
