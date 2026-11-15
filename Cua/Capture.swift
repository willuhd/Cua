import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: – in-memory screenshots (no /tmp, no screencapture file)
// CGWindowListCreateImage captures the window directly to a CGImage. The old
// screencapture+file hop existed only because the CLI had to hand bytes to a
// shell; a menubar process can keep the CGImage/Data in RAM. No Process spawn,
// no ImageSource-from-file, no CGImageDestination-to-file.
func pngData(from image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}
func captureWindowImage(wid: UInt32) -> CGImage? {
    guard wid != 0, let b = windowBounds(wid: wid), b.width > 0, b.height > 0 else { return nil }
    // [.boundsIgnoreFraming] drops the shadow (same fix as screencapture -o).
    let img = CGWindowListCreateImage(b, [.optionIncludingWindow], CGWindowID(wid), [.bestResolution, .boundsIgnoreFraming])
    return img
}
func captureScreenImage() -> CGImage? {
    let dw = CGDisplayBounds(CGMainDisplayID())
    guard dw.width > 0 else { return nil }
    return CGWindowListCreateImage(dw, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
}
func overlayImage(_ image: CGImage, grid: Int, cursor: (Double,Double)?, wid: UInt32?) -> CGImage {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var scaleX: CGFloat = 1, scaleY: CGFloat = 1
    var origin = CGPoint.zero
    if let wid = wid, wid != 0, let b = windowBounds(wid: wid), b.width > 0, b.height > 0 {
        scaleX = CGFloat(w) / b.width; scaleY = CGFloat(h) / b.height
        origin = b.origin
    } else {
        let dw = CGDisplayBounds(CGMainDisplayID())
        if dw.width > 0 { scaleX = CGFloat(w) / dw.width; scaleY = scaleX }
    }
    func toPx(_ p: (Double,Double)) -> CGPoint {
        let lx = (CGFloat(p.0) - origin.x) * scaleX
        let ly = (CGFloat(p.1) - origin.y) * scaleY
        return CGPoint(x: lx, y: CGFloat(h) - ly)
    }
    if grid > 0 {
        let step = CGFloat(grid) * scaleX
        let gp = CGMutablePath()
        var x: CGFloat = 0; while x <= CGFloat(w) { gp.move(to: CGPoint(x: x, y: 0.0)); gp.addLine(to: CGPoint(x: x, y: CGFloat(h))); x += step }
        var y: CGFloat = 0; while y <= CGFloat(h) { gp.move(to: CGPoint(x: 0.0, y: y)); gp.addLine(to: CGPoint(x: CGFloat(w), y: y)); y += step }
        ctx.addPath(gp); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55)); ctx.setLineWidth(2); ctx.strokePath()
        ctx.addPath(gp); ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85)); ctx.setLineWidth(1); ctx.strokePath()
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = nsctx
        let shadow = NSShadow(); shadow.shadowColor = .black; shadow.shadowBlurRadius = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white, .shadow: shadow]
        var gx = 0; while CGFloat(gx) * scaleX <= CGFloat(w) {
            let px = CGFloat(gx) * scaleX
            ("\(Int(origin.x) + gx)" as NSString).draw(at: NSPoint(x: px + 3, y: CGFloat(h) - 14), withAttributes: attrs)
            gx += grid
        }
        var gy = 0; while CGFloat(gy) * scaleY <= CGFloat(h) {
            let py = CGFloat(h) - CGFloat(gy) * scaleY
            ("\(Int(origin.y) + gy)" as NSString).draw(at: NSPoint(x: 3, y: py - 14), withAttributes: attrs)
            gy += grid
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    if let c = cursor {
        let p = toPx(c)
        let magenta = CGColor(red: 1, green: 0, blue: 1, alpha: 1)
        ctx.setLineWidth(7); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.strokeEllipse(in: CGRect(x: p.x-15, y: p.y-15, width: 30, height: 30))
        ctx.move(to: CGPoint(x: p.x-24, y: p.y)); ctx.addLine(to: CGPoint(x: p.x+24, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y-24)); ctx.addLine(to: CGPoint(x: p.x, y: p.y+24)); ctx.strokePath()
        ctx.setLineWidth(3.5); ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.strokeEllipse(in: CGRect(x: p.x-15, y: p.y-15, width: 30, height: 30))
        ctx.move(to: CGPoint(x: p.x-24, y: p.y)); ctx.addLine(to: CGPoint(x: p.x+24, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y-24)); ctx.addLine(to: CGPoint(x: p.x, y: p.y+24)); ctx.strokePath()
        ctx.setLineWidth(2); ctx.setStrokeColor(magenta)
        ctx.strokeEllipse(in: CGRect(x: p.x-15, y: p.y-15, width: 30, height: 30))
        ctx.move(to: CGPoint(x: p.x-24, y: p.y)); ctx.addLine(to: CGPoint(x: p.x+24, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y-24)); ctx.addLine(to: CGPoint(x: p.x, y: p.y+24)); ctx.strokePath()
        ctx.setFillColor(magenta)
        ctx.fillEllipse(in: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8))
    }
    return ctx.makeImage() ?? image
}
func captureScreenshotData(wid: UInt32?, grid: Int, cursor: (Double,Double)?) -> Data? {
    let raw: CGImage? = (wid != nil && wid! != 0) ? captureWindowImage(wid: wid!) : captureScreenImage()
    guard let img = raw else { return nil }
    let out = overlayImage(img, grid: grid, cursor: cursor, wid: wid)
    return pngData(from: out)
}

