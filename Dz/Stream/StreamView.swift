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
    private let stateLock = NSLock()

    override init(frame: NSRect) {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init(frame: frame)
        wantsLayer = true
        guard let device, let layer = layer as? CAMetalLayer ?? makeLayer(device) else { return }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsGravity = .resizeAspect
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        buildPipeline(device: device, pixelFormat: layer.pixelFormat)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeLayer(_ device: MTLDevice) -> CAMetalLayer? {
        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        layer = metalLayer
        return metalLayer
    }

    override var isFlipped: Bool { true }

    /// Hands a decoded frame to the display. Safe to call from the decode queue.
    func display(_ buffer: CVPixelBuffer) {
        stateLock.lock()
        currentFrame = buffer
        stateLock.unlock()
        needsDisplay = true
    }

    private func buildPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        // One triangle that covers the view; uv is derived from the clip
        // position so there is no vertex buffer to keep in sync.
        vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
            float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
            float2 p = corners[vid];
            VertexOut out;
            out.position = float4(p, 0.0, 1.0);
            out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
            return out;
        }

        fragment float4 fragment_main(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
            return tex.sample(s, in.uv);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vertexFn = library.makeFunction(name: "vertex_main"),
              let fragmentFn = library.makeFunction(name: "fragment_main") else { return }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let device, let queue, let pipeline, let textureCache,
              let layer = layer as? CAMetalLayer,
              let drawable = layer.nextDrawable(),
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
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        applyPointerCapture()
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
        if kind != .flagsChanged { out.characters = event.characters }
        out.timestampMicros = DispatchTime.now().uptimeNanoseconds / 1000
        return out
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
        onInput?(out)
    }

}
