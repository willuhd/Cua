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
    var CGEventSetWindowLocationFn: (@convention(c) (CGEvent, CGPoint) -> Int32)?
    var AXGetWindowFn: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32)?
    init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let h = dlopen(path, RTLD_NOW) else { return }
        SLEventPostToPid = unsafeBitCast(dlsym(h, "SLEventPostToPid"), to: ((@convention(c) (Int32, CGEvent) -> Int32)?.self))
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
}

