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

        // SVT dereferences p_buffer as an EbSvtIOFormat, so the planes have to
        // be described rather than handed over as one flat block.
        let w = settings.width, h = settings.height
        let lumaBytes = w * h
        let chromaBytes = (w / 2) * (h / 2)

        let hdr = UnsafeMutablePointer<EbBufferHeaderType>.allocate(capacity: 1)
        hdr.initialize(to: EbBufferHeaderType())
        let planes = UnsafeMutablePointer<EbSvtIOFormat>.allocate(capacity: 1)
        planes.initialize(to: EbSvtIOFormat())
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        pixels.copyMemory(from: nv12, byteCount: byteCount)
        inFlight.append(UnsafeMutableRawPointer(hdr))
        inFlight.append(UnsafeMutableRawPointer(planes))
        inFlight.append(pixels)

        let base = pixels.assumingMemoryBound(to: UInt8.self)
        planes.pointee.luma = base
        // NV12: chroma is interleaved after luma, cb and cr straddle each pair.
        planes.pointee.cb = base + lumaBytes
        planes.pointee.cr = base + lumaBytes + 1
        planes.pointee.y_stride = UInt32(w)
        planes.pointee.cb_stride = UInt32(w / 2)
        planes.pointee.cr_stride = UInt32(w / 2)

        hdr.pointee.size = UInt32(MemoryLayout<EbBufferHeaderType>.size)
        hdr.pointee.p_buffer = UnsafeMutableRawPointer(planes).assumingMemoryBound(to: UInt8.self)
        hdr.pointee.n_filled_len = UInt32(byteCount)
        hdr.pointee.n_alloc_len = UInt32(byteCount)
        hdr.pointee.pic_type = EB_AV1_INVALID_PICTURE
        hdr.pointee.pts = pts
        pts += 1
        _ = (lumaBytes, chromaBytes)

        let sent = svt_av1_enc_send_picture(component, hdr)
        guard sent == EB_ErrorNone else { throw EncodeError.send(sent.rawValue) }
        // One picture in, at most one packet out. Asking twice would block,
        // because the encoder has nothing more queued.
        if let packet = try nextPacket(component, flushing: false) { return [packet] }
        return []
    }

    /// Sends end of stream and drains everything still inside the encoder.
    func finish() throws -> [Data] {
        guard let component else { return [] }
        // End of stream is a header carrying the flag, not a null pointer.
        let eos = UnsafeMutablePointer<EbBufferHeaderType>.allocate(capacity: 1)
        eos.initialize(to: EbBufferHeaderType())
        eos.pointee.size = UInt32(MemoryLayout<EbBufferHeaderType>.size)
        eos.pointee.flags = UInt32(EB_BUFFERFLAG_EOS)
        eos.pointee.pic_type = EB_AV1_INVALID_PICTURE
        inFlight.append(UnsafeMutableRawPointer(eos))
        _ = svt_av1_enc_send_picture(component, eos)
        var out: [Data] = []
        while let packet = try nextPacket(component, flushing: true) { out.append(packet) }
        return out
    }

    /// Returns one packet, or nil when the encoder has nothing ready.
    private func nextPacket(_ component: UnsafeMutablePointer<EbComponentType>,
                            flushing: Bool) throws -> Data? {
        var packet: UnsafeMutablePointer<EbBufferHeaderType>? = nil
        let got = svt_av1_enc_get_packet(component, &packet, UInt8(flushing ? 1 : 0))
        guard got == EB_ErrorNone, packet != nil else { return nil }
        let eos = packet!.pointee.flags & UInt32(EB_BUFFERFLAG_EOS) != 0
        var data: Data? = nil
        if let buffer = packet!.pointee.p_buffer, packet!.pointee.n_filled_len > 0 {
            data = Data(bytes: buffer, count: Int(packet!.pointee.n_filled_len))
        }
        _ = svt_av1_enc_release_out_buffer(&packet)
        return eos && data == nil ? nil : data
    }

    deinit {
        if let component {
            svt_av1_enc_deinit(component)
            svt_av1_enc_deinit_handle(component)
        }
        for pointer in inFlight { pointer.deallocate() }
    }
}
