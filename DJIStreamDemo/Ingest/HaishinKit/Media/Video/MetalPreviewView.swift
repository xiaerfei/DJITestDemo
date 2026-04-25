import CoreMedia
import Metal
import MetalKit

/// Metal-based video preview view. Replaces AVSampleBufferDisplayLayer to eliminate
/// PTS-driven buffering latency. Renders the latest CVPixelBuffer immediately on
/// every display refresh — no queue, no PTS wait, no frame accumulation.
class MetalPreviewView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    // Thread-safe latest frame holder
    private var latestPixelBuffer: CVPixelBuffer?
    private let frameLock = NSLock()

    // MARK: - Shader source (compiled at runtime, no .metallib dependency)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    typedef struct {
        float4 position [[position]];
        float2 texCoord;
    } VertexOut;

    typedef struct {
        float2 scale;
    } AspectUniforms;

    vertex VertexOut vertex_main(uint vid [[vertex_id]], constant AspectUniforms& uniforms [[buffer(0)]]) {
        float2 positions[6] = {
            float2(-1, -1), float2(1, -1), float2(-1, 1),
            float2(-1,  1), float2(1, -1), float2( 1, 1)
        };
        float2 texCoords[6] = {
            float2(0, 1), float2(1, 1), float2(0, 0),
            float2(0, 0), float2(1, 1), float2(1, 0)
        };
        VertexOut out;
        out.position = float4(positions[vid].x * uniforms.scale.x,
                              positions[vid].y * uniforms.scale.y, 0, 1);
        out.texCoord = texCoords[vid];
        return out;
    }

    fragment float4 fragment_main(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> yTexture [[texture(0)]],
        texture2d<float, access::sample> cbCrTexture [[texture(1)]]
    ) {
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        float y  = yTexture.sample(s, in.texCoord).r;
        float2 cbcr = cbCrTexture.sample(s, in.texCoord).rg;

        // BT.601 full range (NV12 = full range by default)
        float cb = cbcr.r - 0.5;
        float cr = cbcr.g - 0.5;
        float r = y                + 1.402    * cr;
        float g = y - 0.344136 * cb - 0.714136 * cr;
        float b = y + 1.772    * cb;
        return float4(r, g, b, 1.0);
    }
    """

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let device = device ?? MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!

        // Create texture cache for zero-copy IOSurface → MTLTexture
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache!

        // Compile shader from source at runtime — avoids "no default library" crash
        // on Designed-for-iPad / Mac Catalyst where default.metallib may not be found.
        let library = try! device.makeLibrary(source: Self.shaderSource, options: nil)
        let vertexFunc = library.makeFunction(name: "vertex_main")!
        let fragmentFunc = library.makeFunction(name: "fragment_main")!

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        super.init(frame: frameRect, device: device)

        self.delegate = self
        self.enableSetNeedsDisplay = false
        self.isPaused = false    // continuous 60 fps rendering
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.backgroundColor = .black
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Called from decode pipeline: update the latest frame.
    /// Thread-safe — may be called from any queue.
    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        frameLock.lock()
        latestPixelBuffer = pixelBuffer
        frameLock.unlock()
    }

    /// Clear current frame (called on stop).
    func clearFrame() {
        frameLock.lock()
        latestPixelBuffer = nil
        frameLock.unlock()
    }

    /// Create a Metal texture from a specific plane of a CVPixelBuffer.
    private func makeTextureFromBuffer(_ pixelBuffer: CVPixelBuffer,
                                       planeIndex: Int,
                                       pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let width: Int
        let height: Int
        if pixelFormat == .r8Unorm {
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
        } else {
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
    }
}

extension MetalPreviewView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No action needed — we recalculate textures from CVPixelBuffer each frame.
    }

    func draw(in view: MTKView) {
        frameLock.lock()
        let pixelBuffer = latestPixelBuffer
        frameLock.unlock()

        guard let pixelBuffer,
              let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor else { return }

        guard let yTexture = makeTextureFromBuffer(pixelBuffer, planeIndex: 0, pixelFormat: .r8Unorm),
              let cbCrTexture = makeTextureFromBuffer(pixelBuffer, planeIndex: 1, pixelFormat: .rg8Unorm) else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        // Compute ScaleAspectFit uniform
        let videoWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let videoHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let viewAspect = drawableSize.width / drawableSize.height
        let videoAspect = videoWidth / videoHeight

        var scale = SIMD2<Float>(1, 1)
        if videoAspect > viewAspect {
            scale.y = Float(viewAspect / videoAspect)
        } else {
            scale.x = Float(videoAspect / viewAspect)
        }

        let uniformBuffer = self.device!.makeBuffer(bytes: &scale, length: MemoryLayout<SIMD2<Float>>.size, options: [])

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(yTexture, index: 0)
        renderEncoder.setFragmentTexture(cbCrTexture, index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
