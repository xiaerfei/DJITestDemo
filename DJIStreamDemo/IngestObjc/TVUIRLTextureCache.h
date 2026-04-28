#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLTextureCache : NSObject

@property (nonatomic, strong, readonly) id<MTLDevice> device;

- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (nullable id<MTLTexture>)textureForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                      planeIndex:(size_t)planeIndex
                                     pixelFormat:(MTLPixelFormat)pixelFormat;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
