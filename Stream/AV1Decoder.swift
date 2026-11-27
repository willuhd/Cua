//
//  AV1Decoder.swift
//  dz
//
//  Drives dav1d in process. One frame at a time, spread over the cores, with
//  no lookahead: a stream has to be decoded as fast as it arrives, and any
//  read-ahead we do here is latency we hand to the pointer.
//

import Foundation

final class AV1Decoder {
    enum DecodeError: Error, CustomStringConvertible {
        case open(Int32)
        case send(Int32)
        case picture(Int32)

        var description: String {
            switch self {
            case .open(let c): return "dav1d_open failed: \(c)"
            case .send(let c): return "dav1d_send_data failed: \(c)"
            case .picture(let c): return "dav1d_get_picture failed: \(c)"
            }
        }
    }

    private var context: OpaquePointer?
    private(set) var width = 0
    private(set) var height = 0

    init(threads: Int = 0) throws {
        var settings = Dav1dSettings()
        dav1d_default_settings(&settings)
        let cores = threads > 0 ? threads : ProcessInfo.processInfo.activeProcessorCount
        settings.n_threads = Int32(max(1, min(cores, 16)))
        // Every picture is asked for as soon as its data goes in, which is what
        // keeps end-to-end latency down on a link that already has 300 ms.
        settings.max_frame_delay = 1
        settings.all_layers = 0

        var ctx: OpaquePointer?
        let opened = dav1d_open(&ctx, &settings)
        guard opened >= 0, let ctx else { throw DecodeError.open(opened) }
        context = ctx
    }

    /// Pushes one packet and returns a frame if the decoder produced one.
    /// A packet does not always yield a frame; that is normal, not an error.
    func decode(_ packet: Data) throws -> (width: Int, height: Int, planes: Int)? {
        guard let context else { return nil }

        var data = Dav1dData()
        // dav1d hands back the buffer it allocated, so the copy is ours to make.
        guard let raw = dav1d_data_create(&data, packet.count) else {
            throw DecodeError.send(-1)
        }
        packet.withUnsafeBytes { src in
            if let base = src.baseAddress {
                UnsafeMutableRawPointer(raw).copyMemory(from: base, byteCount: packet.count)
            }
        }

        var sent = dav1d_send_data(context, &data)
        dav1d_data_unref(&data)
        // EAGAIN means "carry on, I have enough to chew on".
        if sent < 0 && sent != -11 { throw DecodeError.send(sent) }

        var picture = Dav1dPicture()
        var got = dav1d_get_picture(context, &picture)
        if got < 0 && got != -11 { throw DecodeError.picture(got) }
        guard got == 0 else { return nil }

        width = Int(picture.p.w)
        height = Int(picture.p.h)
        dav1d_picture_unref(&picture)
        sent = 0
        got = 0
        return (width, height, 1)
    }

    deinit {
        if context != nil { dav1d_close(&context) }
    }
}
