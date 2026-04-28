#import "TVUIRLTextureCache.h"

@interface TVUIRLTextureCache ()
@property (nonatomic, strong, readwrite) id<MTLDevice> device;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@end

@implementation TVUIRLTextureCache

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (self = [super init]) {
        _device = device;
        CVMetalTextureCacheRef cache = NULL;
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &cache);
        _textureCache = cache;
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

- (nullable id<MTLTexture>)textureForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                      planeIndex:(size_t)planeIndex
                                     pixelFormat:(MTLPixelFormat)pixelFormat {
    if (!self.textureCache || !pixelBuffer) return nil;

    size_t width, height;
    if (planeIndex == 0 && pixelFormat == MTLPixelFormatR8Unorm) {
        width = CVPixelBufferGetWidth(pixelBuffer);
        height = CVPixelBufferGetHeight(pixelBuffer);
    } else {
        width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex);
        height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex);
    }

    CVMetalTextureRef cvTexture = NULL;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        self.textureCache,
        pixelBuffer,
        NULL,
        pixelFormat,
        width,
        height,
        planeIndex,
        &cvTexture
    );

    if (status != kCVReturnSuccess || !cvTexture) return nil;

    id<MTLTexture> texture = CVMetalTextureGetTexture(cvTexture);
    CFRelease(cvTexture);
    return texture;
}

- (void)flush {
    if (self.textureCache) {
        CVMetalTextureCacheFlush(self.textureCache, 0);
    }
}

@end
