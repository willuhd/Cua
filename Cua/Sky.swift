import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – SkyLight private SPI (same as CLI)
final class Sky {
    static let shared = Sky()
    var SLEventPostToPid: (@convention(c) (Int32, CGEvent) -> Int32)?
    var SLPSPostEventRecordTo: (@convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32)?
    var SLPSGetFrontProcess: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32)?
    var CGEventSetWindowLocationFn: (@convention(c) (CGEvent, CGPoint) -> Int32)?
    var SLSMainConnectionID: (@convention(c) () -> Int32)?
    var SLSGetWindowOwner: (@convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32)?
    var SLSGetConnectionPSN: (@convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32)?
    var AXGetWindowFn: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32)?
    var loaded = false
    init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let h = dlopen(path, RTLD_NOW) else { return }
        loaded = true
        SLEventPostToPid = unsafeBitCast(dlsym(h, "SLEventPostToPid"), to: ((@convention(c) (Int32, CGEvent) -> Int32)?.self))
        SLPSPostEventRecordTo = unsafeBitCast(dlsym(h, "SLPSPostEventRecordTo"), to: ((@convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32)?.self))
        SLPSGetFrontProcess = unsafeBitCast(dlsym(h, "SLPSGetFrontProcess"), to: ((@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32)?.self))
        SLSMainConnectionID = unsafeBitCast(dlsym(h, "SLSMainConnectionID"), to: ((@convention(c) () -> Int32)?.self))
        SLSGetWindowOwner = unsafeBitCast(dlsym(h, "SLSGetWindowOwner"), to: ((@convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32)?.self))
        SLSGetConnectionPSN = unsafeBitCast(dlsym(h, "SLSGetConnectionPSN"), to: ((@convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32)?.self))
        var p = dlsym(h, "CGEventSetWindowLocation")
        if p == nil, let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) {
            p = dlsym(cg, "CGEventSetWindowLocation")
        }
        if let p = p {
            CGEventSetWindowLocationFn = unsafeBitCast(p, to: ((@convention(c) (CGEvent, CGPoint) -> Int32)?.self))
        }
        if let as2 = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
           let q = dlsym(as2, "_AXUIElementGetWindow") {
            AXGetWindowFn = unsafeBitCast(q, to: ((@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32)?.self))
        }
    }
    func psnForWindow(_ wid: UInt32) -> ProcessSerialNumber? {
        guard let cidFn = SLSMainConnectionID, let ownerFn = SLSGetWindowOwner, let psnFn = SLSGetConnectionPSN else { return nil }
        let cid = cidFn()
        var ownerConn: Int32 = 0
        guard ownerFn(cid, wid, &ownerConn) == 0 else { return nil }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard psnFn(ownerConn, &psn) == 0 else { return nil }
        return psn
    }
}

