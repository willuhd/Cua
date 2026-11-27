//
//  AV1Decoder.swift
//  dz
//
//  Drives dav1d in process and hands back a real frame.
//
//  One frame at a time, spread over the cores, with no lookahead: a stream has
//  to be decoded as fast as it arrives, and any read-ahead is latency handed
//  to the pointer.
//
//  dav1d can refuse a packet it is not ready for (EAGAIN). That packet is kept
//  and offered again on the next call rather than dropped, because silently
//  losing input frames looks exactly like a bad network.
//

import Foundation
import CoreVideo

final class AV1Decoder {
    enum DecodeError: Error, CustomStringConvertible {
        case open(Int32)
        case send(Int32)
        case picture(Int32)
        case buffer

        var description: String {
            switch self {
            case .open(let c): return "dav1d_open failed: " + String(c)
            case .send(let c): return "dav1d_send_data failed: " + String(c)
            case .picture(let c): return "dav1d_get_picture failed: " + String(c)
            case .buffer: return "could not copy the decoded picture"
            }
        }
    }

    private var context: OpaquePointer?
    /// A packet dav1d declined to consume, retried on the next call.
    private var carry: Dav1dData?

    private(set) var width = 0
    private(set) var height = 0

    init(threads: Int = 0) throws {
        var settings = Dav1dSettings()
        dav1d_default_settings(&settings)
        let cores = threads > 0 ? threads : ProcessInfo.processInfo.activeProcessorCount
        settings.n_threads = Int32(max(1, min(cores, 16)))
        settings.max_frame_delay = 1
        settings.all_layers = 0

        var ctx: OpaquePointer?
        let opened = dav1d_open(&ctx, &settings)
        guard opened >= 0, let ctx else { throw DecodeError.open(opened) }
        context = ctx
    }

    /// Pushes one packet and returns a decoded frame if one came out.
    func decode(_ packet: Data) throws -> CVPixelBuffer? {
        guard let context else { return nil }

        if carry != nil {
            if let frame = try pump(context, flushingCarry: true) { return frame }
            if carry != nil { return nil }
        }

        var data = Dav1dData()
        guard let raw = dav1d_data_create(&data, packet.count) else {
            throw DecodeError.send(-1)
        }
        packet.withUnsafeBytes { source in
            if let base = source.baseAddress {
                UnsafeMutableRawPointer(raw).copyMemory(from: base, byteCount: packet.count)
            }
        }

        let sent = dav1d_send_data(context, &data)
        if sent < 0 && sent != -11 {
            dav1d_data_unref(&data)
            throw DecodeError.send(sent)
        }
        if sent == -11 {
            if let frame = try pump(context, flushingCarry: false) {
                carry = data
                return frame
            }
            carry = data
            return nil
        }
        dav1d_data_unref(&data)
        return try pump(context, flushingCarry: false)
    }

    private func pump(_ context: OpaquePointer, flushingCarry: Bool) throws -> CVPixelBuffer? {
        var picture = Dav1dPicture()
        let got = dav1d_get_picture(context, &picture)
        if got == 0 {
            let frame = try copyOut(picture)
            dav1d_picture_unref(&picture)
            if flushingCarry, carry != nil {
                var held = carry!
                _ = dav1d_send_data(context, &held)
                dav1d_data_unref(&held)
                carry = nil
            }
            return frame
        }
        if got != -11 { throw DecodeError.picture(got) }
        return nil
    }

    /// Copies the decoded planes into a CVPixelBuffer the renderer can take.
    private func copyOut(_ picture: Dav1dPicture) throws -> CVPixelBuffer {
        let w = Int(picture.p.w)
        let h = Int(picture.p.h)
        width = w
        height = h

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8Planar,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_420YpCbCr8Planar,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw DecodeError.buffer }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let chromaWidth = (w + 1) / 2
        let chromaHeight = (h + 1) / 2
        let sizes = [(w, h), (chromaWidth, chromaHeight), (chromaWidth, chromaHeight)]
        // data and stride are fixed C tuples, so they are lifted into arrays.
        let sources = [picture.data.0, picture.data.1, picture.data.2]
        let strides = [picture.stride.0, picture.stride.1, picture.stride.1]

        for plane in 0..<3 {
            guard let source = sources[plane] else { continue }
            guard let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let sourceStride = Int(strides[plane])
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let planeWidth = sizes[plane].0
            let planeHeight = sizes[plane].1
            let rowBytes = min(sourceStride, destinationStride, planeWidth)
            for row in 0..<planeHeight {
                let from = source.advanced(by: row * sourceStride)
                let to = destination.advanced(by: row * destinationStride)
                to.copyMemory(from: from, byteCount: rowBytes)
            }
        }
        return buffer
    }

    deinit {
        if carry != nil { var held = carry!; dav1d_data_unref(&held) }
        if context != nil { dav1d_close(&context) }
    }
}
