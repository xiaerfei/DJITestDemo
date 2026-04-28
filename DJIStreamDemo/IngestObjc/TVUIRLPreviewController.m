#import "TVUIRLPreviewController.h"
#import "TVUIRLTextureCache.h"
#import "TVUIRLShaderProgram.h"
#import <MetalKit/MetalKit.h>

static NSString *const kShaderSource = @"\n"
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"typedef struct {\n"
"    float4 position [[position]];\n"
"    float2 texCoord;\n"
"} VertexOut;\n"
"\n"
"typedef struct {\n"
"    float2 scale;\n"
"} AspectUniforms;\n"
"\n"
"vertex VertexOut vertex_main(uint vid [[vertex_id]], constant AspectUniforms& uniforms [[buffer(0)]]) {\n"
"    float2 positions[6] = {\n"
"        float2(-1, -1), float2(1, -1), float2(-1, 1),\n"
"        float2(-1,  1), float2(1, -1), float2( 1, 1)\n"
"    };\n"
"    float2 texCoords[6] = {\n"
"        float2(0, 1), float2(1, 1), float2(0, 0),\n"
"        float2(0, 0), float2(1, 1), float2(1, 0)\n"
"    };\n"
"    VertexOut out;\n"
"    out.position = float4(positions[vid].x * uniforms.scale.x,\n"
"                          positions[vid].y * uniforms.scale.y, 0, 1);\n"
"    out.texCoord = texCoords[vid];\n"
"    return out;\n"
"}\n"
"\n"
"fragment float4 fragment_main(\n"
"    VertexOut in [[stage_in]],\n"
"    texture2d<float, access::sample> yTexture [[texture(0)]],\n"
"    texture2d<float, access::sample> cbCrTexture [[texture(1)]]\n"
") {\n"
"    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float y  = yTexture.sample(s, in.texCoord).r;\n"
"    float2 cbcr = cbCrTexture.sample(s, in.texCoord).rg;\n"
"    float cb = cbcr.r - 0.5;\n"
"    float cr = cbcr.g - 0.5;\n"
"    float r = y                + 1.402    * cr;\n"
"    float g = y - 0.344136 * cb - 0.714136 * cr;\n"
"    float b = y + 1.772    * cb;\n"
"    return float4(r, g, b, 1.0);\n"
"}\n";

@interface TVUIRLPreviewMetalView : MTKView <MTKViewDelegate>
@property (nonatomic, strong) TVUIRLTextureCache *textureCache;
@property (nonatomic, strong) TVUIRLShaderProgram *shaderProgram;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) NSLock *frameLock;
@end

@implementation TVUIRLPreviewMetalView {
    CVPixelBufferRef _latestPixelBuffer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super initWithCoder:coder]) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _frameLock = [[NSLock alloc] init];
    _latestPixelBuffer = NULL;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.device = device;
    self.commandQueue = [device newCommandQueue];

    _textureCache = [[TVUIRLTextureCache alloc] initWithDevice:device];

    _shaderProgram = [[TVUIRLShaderProgram alloc] initWithDevice:device];
    [_shaderProgram createPipelineWithSource:kShaderSource
                              vertexFunction:@"vertex_main"
                            fragmentFunction:@"fragment_main"
                                 pixelFormat:MTLPixelFormatBGRA8Unorm];

    self.delegate = self;
    self.enableSetNeedsDisplay = NO;
    self.paused = NO;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.clearColor = MTLClearColorMake(0, 0, 0, 1);
    self.backgroundColor = [UIColor blackColor];
}

- (void)dealloc {
    if (_latestPixelBuffer) {
        CFRelease(_latestPixelBuffer);
    }
}

- (void)updateFrame:(CVPixelBufferRef)pixelBuffer {
    [self.frameLock lock];
    if (_latestPixelBuffer) {
        CFRelease(_latestPixelBuffer);
    }
    _latestPixelBuffer = pixelBuffer;
    if (_latestPixelBuffer) {
        CFRetain(_latestPixelBuffer);
    }
    [self.frameLock unlock];
}

- (void)clearFrame {
    [self.frameLock lock];
    if (_latestPixelBuffer) {
        CFRelease(_latestPixelBuffer);
        _latestPixelBuffer = NULL;
    }
    [self.frameLock unlock];
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView *)view {
    [self.frameLock lock];
    CVPixelBufferRef pixelBuffer = _latestPixelBuffer;
    if (pixelBuffer) {
        CFRetain(pixelBuffer);
    }
    [self.frameLock unlock];

    if (!pixelBuffer) return;

    id<MTLTexture> yTexture = [self.textureCache textureForPixelBuffer:pixelBuffer
                                                            planeIndex:0
                                                           pixelFormat:MTLPixelFormatR8Unorm];
    id<MTLTexture> cbCrTexture = [self.textureCache textureForPixelBuffer:pixelBuffer
                                                               planeIndex:1
                                                              pixelFormat:MTLPixelFormatRG8Unorm];
    if (!yTexture || !cbCrTexture) {
        CFRelease(pixelBuffer);
        return;
    }

    id<CAMetalDrawable> drawable = self.currentDrawable;
    MTLRenderPassDescriptor *passDesc = self.currentRenderPassDescriptor;
    if (!drawable || !passDesc) {
        CFRelease(pixelBuffer);
        return;
    }

    id<MTLCommandBuffer> cmdBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cmdBuffer renderCommandEncoderWithDescriptor:passDesc];
    if (!encoder) {
        CFRelease(pixelBuffer);
        return;
    }

    CGFloat videoWidth = CVPixelBufferGetWidth(pixelBuffer);
    CGFloat videoHeight = CVPixelBufferGetHeight(pixelBuffer);
    CGFloat viewAspect = self.drawableSize.width / self.drawableSize.height;
    CGFloat videoAspect = videoWidth / videoHeight;

    simd_float2 scale = (simd_float2){1.0f, 1.0f};
    if (videoAspect > viewAspect) {
        scale.y = (float)(viewAspect / videoAspect);
    } else {
        scale.x = (float)(videoAspect / viewAspect);
    }

    [encoder setRenderPipelineState:self.shaderProgram.pipelineState];
    [encoder setVertexBytes:&scale length:sizeof(scale) atIndex:0];
    [encoder setFragmentTexture:yTexture atIndex:0];
    [encoder setFragmentTexture:cbCrTexture atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [encoder endEncoding];

    [cmdBuffer presentDrawable:drawable];
    [cmdBuffer commit];

    CFRelease(pixelBuffer);
}

@end

#pragma mark - TVUIRLPreviewController

@interface TVUIRLPreviewController ()
@property (nonatomic, strong, readwrite) UIView *view;
@property (nonatomic, strong) TVUIRLPreviewMetalView *metalView;
@end

@implementation TVUIRLPreviewController

- (instancetype)init {
    if (self = [super init]) {
        _metalView = [[TVUIRLPreviewMetalView alloc] initWithFrame:CGRectZero];
        _view = _metalView;
    }
    return self;
}

- (void)updateFrame:(CVPixelBufferRef)pixelBuffer {
    [self.metalView updateFrame:pixelBuffer];
}

- (void)clearFrame {
    [self.metalView clearFrame];
}

@end
