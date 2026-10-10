//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Metal
import MetalKit
import Synchronization
import UIKit

/// Uploads the three I420 planes as R8 textures straight from the frame's memory and converts to
/// RGB on the GPU (BT.601 limited range, what libwebrtc decodes to). Rotation, mirroring, fitting
/// or filling, zoom and pan are all one vertex transform, so no pixel is touched on the CPU: see
/// ``VideoPresentation/transform(frameWidth:frameHeight:rotation:isMirrored:drawableSize:)``.
@available(iOS 18, *)
final nonisolated class I420MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Uniforms { float4x4 transform; };
    vertex Vertex i420_vertex(uint id [[vertex_id]], constant Uniforms &uniforms [[buffer(0)]]) {
        float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        Vertex out;
        out.position = uniforms.transform * float4(positions[id], 0, 1);
        out.uv = uvs[id];
        return out;
    }
    fragment float4 i420_fragment(Vertex in [[stage_in]],
                                  texture2d<float> yTexture [[texture(0)]],
                                  texture2d<float> uTexture [[texture(1)]],
                                  texture2d<float> vTexture [[texture(2)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = (yTexture.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
        float u = uTexture.sample(s, in.uv).r - 0.5;
        float v = vTexture.sample(s, in.uv).r - 0.5;
        float3 rgb = float3(y + 1.402 * v, y - 0.344136 * u - 0.714136 * v, y + 1.772 * u);
        return float4(clamp(rgb, 0.0, 1.0), 1.0);
    }
    """
    
    private struct Uniforms {
        var transform: simd_float4x4
    }
    
    let slot: VideoFrameSlot
    /// The upright size of the picture, whenever it changes. The view needs it to report a drawn
    /// size that excludes the letterbox, and the gesture layer needs it to clamp a pan; the renderer
    /// is the only place that sees it.
    private let onContentSize: @Sendable (CGSize) -> Void
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var textures: (y: MTLTexture, u: MTLTexture, v: MTLTexture)?
    private var textureSize = (0, 0)
    private var lastFrame: MatrixRTCVideoFrame?
    /// What `textures` currently holds. A pan or a zoom redraws without a new frame, and without
    /// this every tick would re-upload three unchanged planes: about 3 MB a tick at 1080p.
    private var uploadedFrame: MatrixRTCVideoFrame?
    private var lastContentSize: CGSize = .zero
    private var presentation = VideoPresentation.fill
    private var isReleased = false
    
    /// Made once for every tile: per renderer, each tile mounting compiled the shader on the main
    /// thread, and a scroll mounts a row of tiles at every band edge it crosses.
    private final class GPU: @unchecked Sendable {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        
        init?() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let commandQueue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: I420MetalRenderer.shaderSource, options: nil) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "i420_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "i420_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            self.device = device
            self.commandQueue = commandQueue
            self.pipeline = pipeline
        }
    }
    
    private static let gpu = GPU()
    
    /// What the view draws with: the one device every renderer shares.
    static var device: MTLDevice? {
        gpu?.device
    }
    
    init?(slot: VideoFrameSlot, onContentSize: @escaping @Sendable (CGSize) -> Void = { _ in }) {
        guard let gpu = Self.gpu else { return nil }
        self.slot = slot
        self.onContentSize = onContentSize
        device = gpu.device
        commandQueue = gpu.commandQueue
        pipeline = gpu.pipeline
        super.init()
    }
    
    /// Releasing and drawing are mutually exclusive: SwiftUI can tear the view down while a frame
    /// is being uploaded.
    func release() {
        lock.withLock {
            isReleased = true
            lastFrame = nil
            uploadedFrame = nil
            textures = nil
        }
    }
    
    /// Set from the view, read inside the draw, under the same lock as the textures. With
    /// `isPaused` and `enableSetNeedsDisplay` the draw is main-thread work, so this never contends
    /// in practice; a second primitive would only raise the question of which one orders what
    /// against ``release()``.
    func setPresentation(_ presentation: VideoPresentation) {
        lock.withLock { self.presentation = presentation }
    }
    
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    
    func draw(in view: MTKView) {
        // Never touch the GPU while inactive: `currentDrawable` blocks and the system kills the app.
        guard UIApplication.shared.applicationState == .active else { return }
        // Reported after the lock is given up rather than inside it: the callback hops to the main
        // actor and ends up back here setting a presentation, which on the same thread would
        // deadlock on a lock that is not reentrant.
        let contentSize: CGSize? = lock.withLock {
            guard !isReleased else { return nil }
            if let frame = slot.take() {
                lastFrame = frame
            }
            guard let frame = lastFrame,
                  let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
            
            if uploadedFrame !== frame {
                upload(frame)
                uploadedFrame = frame
            }
            guard let textures else { return nil }
            
            var uniforms = Uniforms(transform: presentation.transform(frameWidth: frame.width,
                                                                      frameHeight: frame.height,
                                                                      rotation: frame.rotation,
                                                                      isMirrored: frame.isMirrored,
                                                                      drawableSize: view.drawableSize))
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return nil }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(textures.y, index: 0)
            encoder.setFragmentTexture(textures.u, index: 1)
            encoder.setFragmentTexture(textures.v, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            
            let rotated = frame.rotation == .deg90 || frame.rotation == .deg270
            let size = CGSize(width: rotated ? frame.height : frame.width,
                              height: rotated ? frame.width : frame.height)
            guard size != lastContentSize else { return nil }
            lastContentSize = size
            return size
        }
        if let contentSize {
            onContentSize(contentSize)
        }
    }
    
    // MARK: - Private
    
    private func upload(_ frame: MatrixRTCVideoFrame) {
        if textures == nil || textureSize != (frame.width, frame.height) {
            textures = makeTextures(width: frame.width, height: frame.height)
            textureSize = (frame.width, frame.height)
        }
        guard let textures else { return }
        // replaceRegion copies synchronously, so the frame may be released right after this returns.
        frame.withPlanes { y, u, v in
            textures.y.replace(region: MTLRegionMake2D(0, 0, y.width, y.height), mipmapLevel: 0, withBytes: y.pointer, bytesPerRow: y.stride)
            textures.u.replace(region: MTLRegionMake2D(0, 0, u.width, u.height), mipmapLevel: 0, withBytes: u.pointer, bytesPerRow: u.stride)
            textures.v.replace(region: MTLRegionMake2D(0, 0, v.width, v.height), mipmapLevel: 0, withBytes: v.pointer, bytesPerRow: v.stride)
        }
    }
    
    private func makeTextures(width: Int, height: Int) -> (MTLTexture, MTLTexture, MTLTexture)? {
        func make(_ width: Int, _ height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            return device.makeTexture(descriptor: descriptor)
        }
        guard let y = make(width, height), let u = make((width + 1) / 2, (height + 1) / 2), let v = make((width + 1) / 2, (height + 1) / 2) else { return nil }
        return (y, u, v)
    }
}
