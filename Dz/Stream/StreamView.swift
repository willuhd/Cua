//
//  StreamView.swift
//  dz
//
//  Draws decoded frames. A CAMetalLayer takes the CVPixelBuffer straight from
//  the decoder through a texture cache, so a frame goes from dav1d to the
//  screen without a CPU copy or a colour conversion.
//
//  The shader is compiled at runtime rather than from a .metal file: it is
//  fifteen lines and this keeps the target free of another build setting.
//

import Cocoa
import Metal
import MetalKit
import CoreVideo

final class StreamView: NSView {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    private var currentFrame: CVPixelBuffer?
    private var statusText = "Waiting for frames..."
    private var statusLayer: CATextLayer?
    private var framesSeen = 0
    /// Counts draw calls, so a headless check can tell whether AppKit ever
    /// asked us to render.
    private(set) var drawCount = 0
    private(set) var presentCount = 0
    private let stateLock = NSLock()

    override init(frame: NSRect) {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init(frame: frame)
        wantsLayer = true
    }

    /// Everything Metal is built here rather than in init.
    ///
    /// A view outside a window has no backing layer yet, so configuring in
    /// init silently did nothing: no pipeline, no texture cache, no drawable,
    /// and a window that stayed blank while input on the same view worked.
    private func setupIfNeeded() {
        guard pipeline == nil, let device, let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.allowsNextDrawableTimeout = false
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        buildPipeline(device: device, pixelFormat: metalLayer.pixelFormat)

        let text = CATextLayer()
        text.fontSize = 13
        text.alignmentMode = .center
        text.foregroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
        text.contentsScale = 2
        metalLayer.addSublayer(text)
        statusLayer = text

        updateDrawableSize()
        updateStatusLayer()
    }

    /// What to show before the first frame, so a viewer knows what stage it is
    /// at rather than staring at black.
    func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusText = text
            self.updateStatusLayer()
            self.renderNow()
        }
    }

    private func updateStatusLayer() {
        guard let statusLayer, let metalLayer = layer as? CAMetalLayer else { return }
        let show = framesSeen == 0
        statusLayer.isHidden = !show
        guard show else { return }
        let scale = window?.backingScaleFactor ?? 2
        statusLayer.contentsScale = scale
        statusLayer.string = statusText
        statusLayer.frame = CGRect(x: 0, y: (bounds.height - 20) / 2,
                                   width: bounds.width, height: 20)
        _ = metalLayer
    }

    /// A CAMetalLayer renders into whatever its drawable size says. Left at
    /// zero, which is the default, every nextDrawable returns nil and the view
    /// stays blank however many frames arrive.
    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.isOpaque = true
        return metalLayer
    }

    private func updateDrawableSize() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let drawable = CGSize(width: size.width * scale, height: size.height * scale)
        if metalLayer.drawableSize != drawable {
            metalLayer.drawableSize = drawable
            metalLayer.needsDisplayOnBoundsChange = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        updateStatusLayer()
        renderNow()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        needsDisplay = true
    }


    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Hands a decoded frame to the display. Safe to call from the decode queue.
    func display(_ buffer: CVPixelBuffer) {
        stateLock.lock()
        currentFrame = buffer
        framesSeen += 1
        let first = framesSeen == 1
        stateLock.unlock()
        if first {
            DispatchQueue.main.async { [weak self] in
                self?.statusLayer?.isHidden = true
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.renderNow()
        }
    }

    private func buildPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: StreamShaders.source, options: nil),
              let vertexFn = library.makeFunction(name: "vertex_main"),
              let fragmentFn = library.makeFunction(name: "fragment_main") else { return }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    override func draw(_ dirtyRect: NSRect) {
        renderNow()
    }

    /// Draws the current frame and presents it.
    ///
    /// AppKit never calls draw for a view whose backing layer is a
    /// CAMetalLayer, so rendering is driven from here instead: when a frame
    /// arrives, when the view resizes, and when status changes.
    func renderNow() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.renderNow() }
            return
        }
        drawCount += 1
        setupIfNeeded()
        updateDrawableSize()
        guard let device, let queue, let pipeline, let textureCache,
              let metalLayer = layer as? CAMetalLayer,
              metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }

        stateLock.lock()
        let frame = currentFrame
        stateLock.unlock()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let frame {
            var textureRef: CVMetalTexture?
            let width = CVPixelBufferGetWidth(frame)
            let height = CVPixelBufferGetHeight(frame)
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, frame, nil,
                                                      .bgra8Unorm, width, height, 0, &textureRef)
            if let textureRef, let texture = CVMetalTextureGetTexture(textureRef) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        encoder.endEncoding()
        presentCount += 1
        commandBuffer.present(drawable)
        commandBuffer.commit()
        _ = device
    }

    // MARK: - Input

    /// Everything the user does in this view, for the client to ship to the host.
    var onInput: ((InputEvent) -> Void)?

    /// Locked confines and hides the cursor for games; free is ordinary desktop use.
    var pointerCapture: PointerCapture = .free {
        didSet { applyPointerCapture() }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        setupIfNeeded()
        updateDrawableSize()
        renderNow()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        applyPointerCapture()
    }

    private var swipeMonitor: Any?

    /// Trackpad swipes, forwarded as the effect rather than as the gesture:
    /// a three finger swipe is a WindowServer gesture and there is no way to
    /// inject one, so the host is asked to do what the swipe means.
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            var out = InputEvent(kind: .gesture)
            out.dx = Double(event.deltaX.rounded())
            out.dy = Double(event.deltaY.rounded())
            out.timestampMicros = DispatchTime.now().uptimeNanoseconds / 1000
            if out.dx != 0 || out.dy != 0 { self.onInput?(out) }
            return event
        }
    }

    private func removeSwipeMonitor() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }

    private func applyPointerCapture() {
        switch pointerCapture {
        case .locked:
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        case .free:
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    /// Position in the session, normalised 0...1 from the top-left of the view.
    private func normalized(_ point: NSPoint) -> (Double, Double) {
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        return (Double(point.x / bounds.width), Double(point.y / bounds.height))
    }

    /// NSEvent carries Fn as .function; CGEvent calls it maskSecondaryFn. This
    /// mapping is the thing the game-streaming protocols have no slot for.
    private func cgFlags(_ flags: NSEvent.ModifierFlags) -> UInt64 {
        var out: CGEventFlags = []
        if flags.contains(.shift) { out.insert(.maskShift) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.function) { out.insert(.maskSecondaryFn) }
        if flags.contains(.capsLock) { out.insert(.maskAlphaShift) }
        return out.rawValue
    }

    private func keyEvent(_ kind: InputEvent.Kind, _ event: NSEvent) -> InputEvent {
        var out = InputEvent(kind: kind)
        out.code = event.keyCode
        out.flags = cgFlags(event.modifierFlags)
        out.isRepeat = event.isARepeat
        if kind != .flagsChanged {
            out.characters = event.characters
            out.charactersIgnoringModifiers = event.charactersIgnoringModifiers
        }
        out.timestampMicros = DispatchTime.now().uptimeNanoseconds / 1000
        return out
    }

    /// NSEvent and CGEvent number their scroll phases differently, so they are
    /// translated rather than passed through. Passing through works for began
    /// and then quietly breaks momentum.
    private func scrollPhase(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 8 }
        if phase.contains(.mayBegin) { return 128 }
        return 0
    }

    private func momentumPhase(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 3 }
        return 0
    }

    private func mouseEvent(_ kind: InputEvent.Kind, _ event: NSEvent, button: UInt16 = 0) -> InputEvent {
        var out = InputEvent(kind: kind)
        out.code = button
        out.flags = cgFlags(event.modifierFlags)
        let (x, y) = normalized(convert(event.locationInWindow, from: nil))
        out.x = x
        out.y = y
        if pointerCapture == .locked {
            out.dx = Double(event.deltaX)
            out.dy = Double(event.deltaY)
        }
        out.timestampMicros = DispatchTime.now().uptimeNanoseconds / 1000
        return out
    }

    override func keyDown(with event: NSEvent) { onInput?(keyEvent(.keyDown, event)) }
    override func keyUp(with event: NSEvent) { onInput?(keyEvent(.keyUp, event)) }
    override func flagsChanged(with event: NSEvent) { onInput?(keyEvent(.flagsChanged, event)) }

    override func mouseMoved(with event: NSEvent) { onInput?(mouseEvent(.mouseMove, event)) }
    override func mouseDragged(with event: NSEvent) { onInput?(mouseEvent(.mouseDrag, event)) }
    override func mouseDown(with event: NSEvent) { onInput?(mouseEvent(.mouseDown, event)) }
    override func mouseUp(with event: NSEvent) { onInput?(mouseEvent(.mouseUp, event)) }
    override func rightMouseDown(with event: NSEvent) { onInput?(mouseEvent(.mouseDown, event, button: 1)) }
    override func rightMouseUp(with event: NSEvent) { onInput?(mouseEvent(.mouseUp, event, button: 1)) }
    override func otherMouseDown(with event: NSEvent) { onInput?(mouseEvent(.mouseDown, event, button: 2)) }
    override func otherMouseUp(with event: NSEvent) { onInput?(mouseEvent(.mouseUp, event, button: 2)) }

    override func scrollWheel(with event: NSEvent) {
        var out = mouseEvent(.scroll, event)
        out.dx = Double(event.scrollingDeltaX)
        out.dy = Double(event.scrollingDeltaY)
        out.continuous = event.hasPreciseScrollingDeltas
        out.phase = scrollPhase(event.phase)
        out.momentumPhase = momentumPhase(event.momentumPhase)
        onInput?(out)
    }

    override func magnify(with event: NSEvent) {
        var out = InputEvent(kind: .magnify)
        out.magnification = Double(event.magnification)
        out.flags = cgFlags(event.modifierFlags)
        out.timestampMicros = DispatchTime.now().uptimeNanoseconds / 1000
        onInput?(out)
    }

}
