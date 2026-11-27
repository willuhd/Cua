//
//  PixelFormat.swift
//  dz
//
//  ScreenCaptureKit hands back BGRA. SVT-AV1 takes three separate planes with
//  their own strides, so this converts straight to planar I420 rather than
//  NV12: converting to NV12 first would mean de-interleaving chroma by hand
//  afterwards, and getting that wrong yields a valid bitstream with wrong
//  colours, which no amount of frame counting would catch.
//

import Foundation
import CoreVideo
import VideoToolbox

enum PixelFormatError: Error, CustomStringConvertible {
    case session(OSStatus)
    case pool(OSStatus)
    case transfer(OSStatus)

    var description: String {
        switch self {
        case .session(let s): return "could not create the converter (\(s))"
        case .pool(let s): return "could not create a buffer pool (\(s))"
        case .transfer(let s): return "pixel transfer failed (\(s))"
        }
    }
}

/// Converts BGRA into planar I420 (Y, Cb, Cr), which is what SVT reads.
final class I420Converter {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init() throws {
        var created: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created)
        guard status == kCVReturnSuccess, let created else { throw PixelFormatError.session(status) }
        session = created
        // The encoders are happy with video range, and it is what a display
        // stream should be; asking for full range makes the luminance ramp.
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_RealTime,
                             value: kCFBooleanTrue)
    }

    /// The pool is rebuilt only when the geometry changes, so a steady stream
    /// allocates nothing per frame.
    private func buffer(for width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil || width != poolWidth || height != poolHeight {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8Planar,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                                 attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else { throw PixelFormatError.pool(status) }
            pool = created
            poolWidth = width
            poolHeight = height
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw PixelFormatError.pool(status) }
        return buffer
    }

    /// Returns an NV12 buffer for the given BGRA frame.
    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let session else { throw PixelFormatError.session(0) }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let destination = try buffer(for: width, height: height)
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == kCVReturnSuccess else { throw PixelFormatError.transfer(status) }
        return destination
    }

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }
}

/// The three planes of a converted buffer, as SVT wants them.
struct I420Frame {
    let luma: UnsafeMutableRawPointer
    let cb: UnsafeMutableRawPointer
    let cr: UnsafeMutableRawPointer
    let lumaStride: Int
    let cbStride: Int
    let crStride: Int
    let width: Int
    let height: Int
    let backing: CVPixelBuffer

    /// Total bytes SVT will read, which is what it wants in n_filled_len.
    var byteCount: Int {
        lumaStride * height + (cbStride + crStride) * (height / 2)
    }

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(buffer) == 3 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let u = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
              let v = CVPixelBufferGetBaseAddressOfPlane(buffer, 2) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        luma = y
        cb = u
        cr = v
        lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        cbStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        crStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 2)
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        backing = buffer
    }

    func unlock() { CVPixelBufferUnlockBaseAddress(backing, .readOnly) }
}
