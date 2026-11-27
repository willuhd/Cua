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

    /// Hands one frame to the encoder as three planar buffers.
    ///
    /// SVT reads chroma as two separate planes whose stride is the chroma
    /// width, so interleaved NV12 would encode as valid video with the colour
    /// planes reading from the wrong place. Planes are described explicitly and
    /// copied row by row, because a captured buffer's stride is usually wider
    /// than its width.
    func encode(luma: UnsafeRawPointer, cb: UnsafeRawPointer, cr: UnsafeRawPointer,
                yStride: Int, cbStride: Int, crStride: Int) throws -> [Data] {
        guard let component else { throw EncodeError.setup("encoder closed") }
        let w = settings.width, h = settings.height
        let chromaRows = h / 2
        let total = yStride * h + (cbStride + crStride) * chromaRows

        let hdr = UnsafeMutablePointer<EbBufferHeaderType>.allocate(capacity: 1)
        hdr.initialize(to: EbBufferHeaderType())
        let planes = UnsafeMutablePointer<EbSvtIOFormat>.allocate(capacity: 1)
        planes.initialize(to: EbSvtIOFormat())
        let packed = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 64)
        inFlight.append(UnsafeMutableRawPointer(hdr))
        inFlight.append(UnsafeMutableRawPointer(planes))
        inFlight.append(packed)

        let base = packed.assumingMemoryBound(to: UInt8.self)
        base.update(from: luma.assumingMemoryBound(to: UInt8.self), count: yStride * h)
        let cbBase = base + yStride * h
        cbBase.update(from: cb.assumingMemoryBound(to: UInt8.self), count: cbStride * chromaRows)
        let crBase = cbBase + cbStride * chromaRows
        crBase.update(from: cr.assumingMemoryBound(to: UInt8.self), count: crStride * chromaRows)

        planes.pointee.luma = base
        planes.pointee.cb = cbBase
        planes.pointee.cr = crBase
        planes.pointee.y_stride = UInt32(yStride)
        planes.pointee.cb_stride = UInt32(cbStride)
        planes.pointee.cr_stride = UInt32(crStride)

        hdr.pointee.size = UInt32(MemoryLayout<EbBufferHeaderType>.size)
        hdr.pointee.p_buffer = UnsafeMutableRawPointer(planes).assumingMemoryBound(to: UInt8.self)
        hdr.pointee.n_filled_len = UInt32(total)
        hdr.pointee.n_alloc_len = UInt32(total)
        hdr.pointee.pic_type = EB_AV1_INVALID_PICTURE
        hdr.pointee.pts = pts
        pts += 1

        let sent = svt_av1_enc_send_picture(component, hdr)
        guard sent == EB_ErrorNone else { throw EncodeError.send(sent.rawValue) }
        // In low delay the encoder takes one picture and gives one packet back
        // inside this call, so the input is finished with by the time we return.
        // Holding it any longer is what turns a 4 MB frame at 75 fps into
        // hundreds of megabytes a second of retained memory.
        let packet = try nextPacket(component, flushing: false)
        releaseInFlight()
        return packet.map { [$0] } ?? []
    }

    /// Convenience for a converted buffer.
    func encode(frame: I420Frame) throws -> [Data] {
        try encode(luma: UnsafeRawPointer(frame.luma),
                   cb: UnsafeRawPointer(frame.cb),
                   cr: UnsafeRawPointer(frame.cr),
                   yStride: frame.lumaStride,
                   cbStride: frame.cbStride,
                   crStride: frame.crStride)
    }

    /// Convenience for a tightly packed I420 frame, used by tests.
    func encode(i420: UnsafeMutableRawPointer) throws -> [Data] {
        let w = settings.width, h = settings.height, half = UInt32(w / 2)
        let lumaBytes = w * h
        return try encode(luma: UnsafeRawPointer(i420),
                          cb: UnsafeRawPointer(i420 + lumaBytes),
                          cr: UnsafeRawPointer(i420 + lumaBytes + (w / 2) * (h / 2)),
                          yStride: w, cbStride: Int(half), crStride: Int(half))
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
        releaseInFlight()
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

    /// Frees the per-frame input buffers once the encoder has returned a packet.
    private func releaseInFlight() {
        for pointer in inFlight { pointer.deallocate() }
        inFlight.removeAll(keepingCapacity: true)
    }

    deinit {
        if let component {
            svt_av1_enc_deinit(component)
            svt_av1_enc_deinit_handle(component)
        }
        releaseInFlight()
    }
}
