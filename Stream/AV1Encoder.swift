//
//  AV1Encoder.swift
//  dz
//
//  Drives SVT-AV1 in process. One frame in, packets out, on the settings the
//  session was pinned to. No adaptation: the rate controller is told a number
//  and holds it.
//

import Foundation

final class AV1Encoder {
    enum EncodeError: Error, CustomStringConvertible {
        case setup(String)
        case send(Int32)
        case packet(Int32)

        var description: String {
            switch self {
            case .setup(let why): return "encoder setup failed: \(why)"
            case .send(let code): return "encoder send failed: \(code)"
            case .packet(let code): return "encoder packet failed: \(code)"
            }
        }
    }

    private var component: UnsafeMutablePointer<EbComponentType>?
    private var pts: Int64 = 0
    /// SVT holds on to the header and pixel buffer it is given until the packet
    /// comes back, so both are allocated per frame and freed on teardown.
    private var inFlight: [UnsafeMutableRawPointer] = []
    private let settings: StreamSettings

    init(settings: StreamSettings) throws {
        self.settings = try settings.validated()

        var handle: UnsafeMutablePointer<EbComponentType>?
        var cfg = EbSvtAv1EncConfiguration()
        guard svt_av1_enc_init_handle(&handle, &cfg) == EB_ErrorNone, let handle else {
            throw EncodeError.setup("svt_av1_enc_init_handle")
        }
        self.component = handle

        cfg.source_width = UInt32(self.settings.width)
        cfg.source_height = UInt32(self.settings.height)
        cfg.frame_rate_numerator = UInt32(self.settings.frameRate)
        cfg.frame_rate_denominator = 1
        cfg.encoder_bit_depth = UInt32(EB_EIGHT_BIT.rawValue)
        cfg.encoder_color_format = EB_YUV420
        cfg.enc_mode = Int8(self.settings.preset)
        cfg.rate_control_mode = UInt8(self.settings.rateControl == .cbr
                                      ? SVT_AV1_RC_MODE_CBR.rawValue
                                      : SVT_AV1_RC_MODE_VBR.rawValue)
        cfg.target_bit_rate = UInt32(self.settings.bitrate)
        // Low delay: no lookahead, and CBR is refused without it. The library
        // deprecated the P variant, so low delay means LOW_DELAY_B in 3.x.
        cfg.pred_structure = UInt8(SVT_AV1_PRED_LOW_DELAY_B.rawValue)
        // A keyframe every two seconds, so a client that joins late or drops
        // does not wait long to recover.
        cfg.intra_period_length = Int32(self.settings.frameRate * 2)

        let set = svt_av1_enc_set_parameter(handle, &cfg)
        guard set == EB_ErrorNone else { throw EncodeError.setup("set_parameter(\(set.rawValue))") }
        let started = svt_av1_enc_init(handle)
        guard started == EB_ErrorNone else { throw EncodeError.setup("init(\(started.rawValue))") }
    }

    /// Hands one NV12 frame to the encoder. Returns whatever packets come back
    /// immediately; the encoder may return none while it fills its pipeline.
    func encode(nv12: UnsafeMutableRawPointer, byteCount: Int) throws -> [Data] {
        guard let component else { throw EncodeError.setup("encoder closed") }

        let hdr = UnsafeMutablePointer<EbBufferHeaderType>.allocate(capacity: 1)
        hdr.initialize(to: EbBufferHeaderType())
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        pixels.copyMemory(from: nv12, byteCount: byteCount)
        inFlight.append(UnsafeMutableRawPointer(hdr))
        inFlight.append(pixels)

        hdr.pointee.size = UInt32(MemoryLayout<EbBufferHeaderType>.size)
        hdr.pointee.p_buffer = pixels.assumingMemoryBound(to: UInt8.self)
        hdr.pointee.n_filled_len = UInt32(byteCount)
        hdr.pointee.n_alloc_len = UInt32(byteCount)
        hdr.pointee.pts = pts
        pts += 1

        let sent = svt_av1_enc_send_picture(component, hdr)
        guard sent == EB_ErrorNone else { throw EncodeError.send(sent.rawValue) }
        return try drain(component)
    }

    /// Flushes the pipeline at end of stream.
    func finish() throws -> [Data] {
        guard let component else { return [] }
        _ = svt_av1_enc_send_picture(component, nil)
        return try drain(component)
    }

    private func drain(_ component: UnsafeMutablePointer<EbComponentType>) throws -> [Data] {
        var out: [Data] = []
        while true {
            var packet: UnsafeMutablePointer<EbBufferHeaderType>? = nil
            let got = svt_av1_enc_get_packet(component, &packet, UInt8(0))
            guard got == EB_ErrorNone, packet != nil else { break }
            let eos = packet!.pointee.flags & UInt32(EB_BUFFERFLAG_EOS) != 0
            if let buffer = packet!.pointee.p_buffer, packet!.pointee.n_filled_len > 0 {
                out.append(Data(bytes: buffer, count: Int(packet!.pointee.n_filled_len)))
            }
            _ = svt_av1_enc_release_out_buffer(&packet)
            if eos { break }
        }
        return out
    }

    deinit {
        if let component {
            svt_av1_enc_deinit(component)
            svt_av1_enc_deinit_handle(component)
        }
        for pointer in inFlight { pointer.deallocate() }
    }
}
