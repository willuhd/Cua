import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

// MARK: – in-memory screenshots (no /tmp, no screencapture file)
// ScreenCaptureKit (SCScreenshotManager, macOS 14+) captures a window directly
// to a CGImage, so nothing has to be written out and read back: the menubar
// process keeps the CGImage and its PNG in RAM.
// No Process spawn, no ImageSource-from-file, no CGImageDestination-to-file.
func pngData(from image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// SCScreenshotManager is async; the MCP tool path is synchronous, so bridge
// each capture with a bounded wait. A hung SCK call becomes a clean nil result
// instead of pinning the tool queue forever.
private final class CaptureBox<T>: @unchecked Sendable {
    var value: T?
    var error: Error?
}

private func waitForCapture<T>(_ timeout: TimeInterval, _ body: @escaping () async throws -> T) -> T? {
    let sem = DispatchSemaphore(value: 0)
    let box = CaptureBox<T>()
    Task {
        do { box.value = try await body() } catch { box.error = error }
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        clog("screen capture timed out after \(timeout)s")
        return nil
    }
    if let error = box.error {
        clog("screen capture failed: \(error.localizedDescription)")
        return nil
    }
    return box.value
}

// SCShareableContent enumeration is relatively expensive. Keep a very short
// cache so a burst of screenshots (and zoom crops) does not re-enumerate every
// window, but refresh on demand when a new window is not found.
private let shareableLock = NSLock()
private var shareableCache: (content: SCShareableContent, at: Date)?

private func shareableContent() -> SCShareableContent? {
    shareableLock.lock()
    if let cached = shareableCache, Date().timeIntervalSince(cached.at) < 2.0 {
        shareableLock.unlock()
        return cached.content
    }
    shareableLock.unlock()
    guard let content = waitForCapture(10.0, {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }) else { return nil }
    shareableLock.lock()
    shareableCache = (content, Date())
    shareableLock.unlock()
    return content
}

private func findWindow(_ wid: UInt32) -> SCWindow? {
    if let window = shareableContent()?.windows.first(where: { $0.windowID == wid }) {
        return window
    }
    // A new window may have appeared after the cache was filled.
    shareableLock.lock()
    shareableCache = nil
    shareableLock.unlock()
    return shareableContent()?.windows.first(where: { $0.windowID == wid })
}

private func screenshotConfig(for filter: SCContentFilter, ignoreShadows: Bool) -> SCStreamConfiguration {
    let scale = max(CGFloat(filter.pointPixelScale), 1)
    let rect = filter.contentRect
    let config = SCStreamConfiguration()
    config.width = max(Int((rect.width * scale).rounded()), 1)
    config.height = max(Int((rect.height * scale).rounded()), 1)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = ignoreShadows
    config.ignoreShadowsDisplay = ignoreShadows
    config.captureResolution = .best
    return config
}

func captureWindowImage(wid: UInt32) -> CGImage? {
    guard wid != 0, let window = findWindow(wid) else { return nil }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = screenshotConfig(for: filter, ignoreShadows: true)
    return waitForCapture(10.0) {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
func captureScreenImage() -> CGImage? {
    guard let content = shareableContent() else { return nil }
    let displayID = CGMainDisplayID()
    guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
        return nil
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = screenshotConfig(for: filter, ignoreShadows: false)
    return waitForCapture(10.0) {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
func renderSnapshot(source: CGImage, windowBounds: CGRect, region rawRegion: CGRect,
                    maxDimension: Int, grid: Int, cursor: (Double, Double)?,
                    coordSpace: CoordSpace) -> (image: CGImage, width: Int, height: Int)? {
    let region = rawRegion.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard region.width > 0, region.height > 0, windowBounds.width > 0, windowBounds.height > 0 else { return nil }

    let cropRect = CGRect(x: region.minX * CGFloat(source.width),
                          y: region.minY * CGFloat(source.height),
                          width: region.width * CGFloat(source.width),
                          height: region.height * CGFloat(source.height))
        .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height)).integral
    guard let cropped = source.cropping(to: cropRect), cropped.width > 0, cropped.height > 0 else { return nil }

    let cap = maxDimension > 0 ? maxDimension : max(cropped.width, cropped.height)
    let ratio = min(1.0, CGFloat(cap) / CGFloat(max(cropped.width, cropped.height)))
    let outW = max(Int((CGFloat(cropped.width) * ratio).rounded()), 1)
    let outH = max(Int((CGFloat(cropped.height) * ratio).rounded()), 1)

    guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

    func outPoint(fromScreen p: (Double, Double)) -> CGPoint {
        let nx = (CGFloat(p.0) - windowBounds.minX) / windowBounds.width
        let ny = (CGFloat(p.1) - windowBounds.minY) / windowBounds.height
        let x = (nx - region.minX) / region.width * CGFloat(outW)
        let y = (ny - region.minY) / region.height * CGFloat(outH)
        return CGPoint(x: x, y: CGFloat(outH) - y)
    }

    func label(_ value: CGFloat, axis: Int) -> String {
        switch coordSpace {
        case .screen:
            return String(Int(value.rounded()))
        case .norm1000:
            if axis == 0 { return String(Int(((value - windowBounds.minX) / windowBounds.width * 1000).rounded())) }
            return String(Int(((value - windowBounds.minY) / windowBounds.height * 1000).rounded()))
        case .image:
            if axis == 0 { return String(Int(((value - windowBounds.minX) / windowBounds.width * CGFloat(outW)).rounded())) }
            return String(Int(((value - windowBounds.minY) / windowBounds.height * CGFloat(outH)).rounded()))
        }
    }

    if grid > 0 {
        let gp = CGMutablePath()
        var sx = windowBounds.minX + region.minX * windowBounds.width
        while sx <= windowBounds.minX + (region.minX + region.width) * windowBounds.width {
            let x = (sx - windowBounds.minX - region.minX * windowBounds.width) / (region.width * windowBounds.width) * CGFloat(outW)
            gp.move(to: CGPoint(x: x, y: 0)); gp.addLine(to: CGPoint(x: x, y: CGFloat(outH)))
            sx += CGFloat(grid)
        }
        var sy = windowBounds.minY + region.minY * windowBounds.height
        while sy <= windowBounds.minY + (region.minY + region.height) * windowBounds.height {
            let y = (sy - windowBounds.minY - region.minY * windowBounds.height) / (region.height * windowBounds.height) * CGFloat(outH)
            gp.move(to: CGPoint(x: 0, y: y)); gp.addLine(to: CGPoint(x: CGFloat(outW), y: y))
            sy += CGFloat(grid)
        }
        ctx.addPath(gp); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55)); ctx.setLineWidth(2); ctx.strokePath()
        ctx.addPath(gp); ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85)); ctx.setLineWidth(1); ctx.strokePath()

        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = nsctx
        let shadow = NSShadow(); shadow.shadowColor = .black; shadow.shadowBlurRadius = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white, .shadow: shadow]
        var gx = windowBounds.minX + region.minX * windowBounds.width
        while gx <= windowBounds.minX + (region.minX + region.width) * windowBounds.width {
            let x = (gx - windowBounds.minX - region.minX * windowBounds.width) / (region.width * windowBounds.width) * CGFloat(outW)
            (label(gx, axis: 0) as NSString).draw(at: NSPoint(x: x + 3, y: CGFloat(outH) - 15), withAttributes: attrs)
            gx += CGFloat(grid)
        }
        var gy = windowBounds.minY + region.minY * windowBounds.height
        while gy <= windowBounds.minY + (region.minY + region.height) * windowBounds.height {
            let y = (gy - windowBounds.minY - region.minY * windowBounds.height) / (region.height * windowBounds.height) * CGFloat(outH)
            (label(gy, axis: 1) as NSString).draw(at: NSPoint(x: 3, y: CGFloat(outH) - y - 15), withAttributes: attrs)
            gy += CGFloat(grid)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    if let c = cursor {
        let p = outPoint(fromScreen: c)
        let magenta = CGColor(red: 1, green: 0, blue: 1, alpha: 1)
        // A two-tone outline keeps the marker legible on light, dark, and
        // similarly colored backgrounds; magenta is identity, not contrast.
        ctx.setLineWidth(8); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.98))
        ctx.strokeEllipse(in: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
        ctx.move(to: CGPoint(x: p.x - 25, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 25, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y - 25)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 25)); ctx.strokePath()
        ctx.setLineWidth(4); ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.strokeEllipse(in: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
        ctx.move(to: CGPoint(x: p.x - 25, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 25, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y - 25)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 25)); ctx.strokePath()
        ctx.setLineWidth(2.5); ctx.setStrokeColor(magenta)
        ctx.strokeEllipse(in: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
        ctx.move(to: CGPoint(x: p.x - 25, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 25, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y - 25)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 25)); ctx.strokePath()
        ctx.setFillColor(magenta)
        ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
    }

    guard let out = ctx.makeImage() else { return nil }
    return (out, outW, outH)
}

