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
}
