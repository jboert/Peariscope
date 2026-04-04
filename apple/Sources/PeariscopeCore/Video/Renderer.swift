import Foundation
import MetalKit
import CoreVideo
import IOSurface

/// Metal-based renderer that displays decoded CVPixelBuffers with minimal latency.
/// Uses CVMetalTextureCache for proper texture lifecycle management — the cache
/// handles IOSurface retention/release correctly, preventing VT pool buffer leaks.
/// Supports viewport panning for displaying a large desktop on a small screen.
public final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var currentTexture: MTLTexture?
    private var currentCVTexture: CVMetalTexture?  // Must retain to keep MTLTexture valid
    private var currentPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()
    private var isStopped = false

    // Diagnostics
    private var displayCount: Int = 0
    private var drawCount: Int = 0
    private var pendingCommandBuffers: Int = 0
    private var flushCount: Int = 0

    /// Viewport offset in normalized texture coordinates (0-1).
    /// (0,0) = top-left of texture, (1,1) = bottom-right.
    public var viewportOffset: SIMD2<Float> = .zero

    /// Viewport scale: fraction of the texture visible in each dimension.
    /// (1,1) = full texture visible; (0.3, 1.0) = 30% of width, full height.
    public var viewportScale: SIMD2<Float> = .init(1, 1)

    public weak var mtkView: MTKView?

    public init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let commandQueue = device.makeCommandQueue() else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.mtkView = mtkView

        super.init()

        // Create texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache

        mtkView.device = device
        mtkView.delegate = self
        mtkView.framebufferOnly = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false  // Continuous rendering

        setupPipeline()
    }

    private struct Uniforms {
        var uvOffset: SIMD2<Float>
        var uvScale: SIMD2<Float>
    }

    private func setupPipeline() {
        // Simple BGRA passthrough shader with viewport support
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 uvOffset;
            float2 uvScale;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
            float2 positions[3] = {
                float2(-1.0, -1.0),
                float2( 3.0, -1.0),
                float2(-1.0,  3.0)
            };
            float2 texCoords[3] = {
                float2(0.0, 1.0),
                float2(2.0, 1.0),
                float2(0.0, -1.0)
            };

            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        constant Uniforms &u [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float2 uv = in.texCoord * u.uvScale + u.uvOffset;
            return tex.sample(s, uv);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexShader")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[renderer] Failed to create pipeline: \(error)")
        }
    }

    /// Update viewport to center on a normalized cursor position (0-1 in desktop coords).
    public func updateViewport(cursorX: Float, cursorY: Float, textureWidth: Int, textureHeight: Int, viewSize: CGSize) {
        let texAR = Float(textureWidth) / Float(textureHeight)
        let viewAR = Float(viewSize.width) / Float(viewSize.height)

        var scaleX: Float
        var scaleY: Float

        if texAR > viewAR {
            scaleY = 1.0
            scaleX = viewAR / texAR
        } else {
            scaleX = 1.0
            scaleY = texAR / viewAR
        }

        let offsetX = min(max(cursorX - scaleX * 0.5, 0), 1.0 - scaleX)
        let offsetY = min(max(cursorY - scaleY * 0.5, 0), 1.0 - scaleY)

        lock.lock()
        viewportScale = SIMD2<Float>(scaleX, scaleY)
        viewportOffset = SIMD2<Float>(offsetX, offsetY)
        lock.unlock()
    }

    /// Thread-safe setter for viewport offset and scale.
    public func setViewport(offset: SIMD2<Float>, scale: SIMD2<Float>) {
        lock.lock()
        viewportOffset = offset
        viewportScale = scale
        lock.unlock()
    }

    /// Display a decoded BGRA pixel buffer. Called from the decoder output callback.
    /// Thread-safe — can be called from any thread.
    ///
    /// Uses CVMetalTextureCache for proper texture lifecycle management.
    /// The cache handles IOSurface retention correctly, allowing VT to reclaim
    /// pool buffers when textures are released. Flush before creating new textures
    /// to ensure old IOSurface references are released.
    /// Diagnostic summary — called from heartbeat.
    public func diagnosticSummary() -> String {
        lock.lock()
        let pending = pendingCommandBuffers
        lock.unlock()
        return "display=\(displayCount) draw=\(drawCount) pendingGPU=\(pending) flush=\(flushCount)"
    }

    public func display(pixelBuffer: CVPixelBuffer) {
        guard !isStopped else { return }
        guard let textureCache else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        displayCount += 1

        // Flush BEFORE creating new texture — releases old IOSurface references
        // so VT can reclaim pool buffers. Must happen before the guard to prevent
        // unbounded texture leaks if texture creation fails.
        CVMetalTextureCacheFlush(textureCache, 0)
        flushCount += 1

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,  // plane index (BGRA has single plane)
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            NSLog("[renderer-diag] texture creation FAILED: status=%d %dx%d display=#%d", status, width, height, displayCount)
            return
        }

        lock.lock()
        currentTexture = texture
        currentCVTexture = cvTexture  // Must retain — CVMetalTexture owns the MTLTexture
        currentPixelBuffer = pixelBuffer
        lock.unlock()
    }

    /// Sample the average brightness of a small region at normalized coordinates (0-1).
    /// Returns 0.0 (black) to 1.0 (white), or nil if no pixel buffer is available.
    /// Thread-safe — can be called from any thread.
    public func sampleBrightness(atNormalized x: Float, y: Float) -> Float? {
        lock.lock()
        let pixelBuffer = currentPixelBuffer
        lock.unlock()

        guard let pixelBuffer else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return nil }

        let centerX = min(max(Int(x * Float(width)), 0), width - 1)
        let centerY = min(max(Int(y * Float(height)), 0), height - 1)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Sample 5x5 region centered on cursor for stability
        var totalBrightness: Float = 0
        var sampleCount: Float = 0
        for dy in -2...2 {
            for dx in -2...2 {
                let px = min(max(centerX + dx, 0), width - 1)
                let py = min(max(centerY + dy, 0), height - 1)
                let offset = py * bytesPerRow + px * 4
                let ptr = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                // BGRA format
                let b = Float(ptr[0]) / 255.0
                let g = Float(ptr[1]) / 255.0
                let r = Float(ptr[2]) / 255.0
                totalBrightness += 0.299 * r + 0.587 * g + 0.114 * b
                sampleCount += 1
            }
        }
        return totalBrightness / sampleCount
    }

    /// Stop the renderer. Prevents new frames from being displayed or rendered.
    public func stop() {
        lock.lock()
        isStopped = true
        currentTexture = nil
        currentCVTexture = nil
        currentPixelBuffer = nil
        lock.unlock()

        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        mtkView?.isPaused = true
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        drawCount += 1

        lock.lock()
        let texture = currentTexture
        let cvTex = currentCVTexture
        let pixBuf = currentPixelBuffer
        var uniforms = Uniforms(uvOffset: viewportOffset, uvScale: viewportScale)
        lock.unlock()

        guard let texture, let cvTex, let pixBuf,
              let pipelineState,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)

        lock.lock()
        pendingCommandBuffers += 1
        let pending = pendingCommandBuffers
        lock.unlock()

        // Keep CVMetalTexture + pixel buffer alive until GPU finishes rendering.
        // CVMetalTexture must be retained — releasing it invalidates the MTLTexture.
        commandBuffer.addCompletedHandler { [weak self] _ in
            withExtendedLifetime((cvTex, pixBuf)) {}
            guard let self else { return }
            self.lock.lock()
            self.pendingCommandBuffers -= 1
            self.lock.unlock()
        }
        commandBuffer.commit()

        if pending > 3 {
            NSLog("[renderer-diag] HIGH pending command buffers: %d (draw #%d)", pending, drawCount)
        }
    }
}
