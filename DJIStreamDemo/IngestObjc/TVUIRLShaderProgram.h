#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLShaderProgram : NSObject

@property (nonatomic, strong, readonly) id<MTLDevice> device;
@property (nonatomic, strong, readonly, nullable) id<MTLRenderPipelineState> pipelineState;

- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (BOOL)createPipelineWithVertexFunction:(NSString *)vertexFunctionName
                        fragmentFunction:(NSString *)fragmentFunctionName
                             pixelFormat:(MTLPixelFormat)pixelFormat;
- (BOOL)createPipelineWithSource:(NSString *)metalSource
                   vertexFunction:(NSString *)vertexFunctionName
                 fragmentFunction:(NSString *)fragmentFunctionName
                      pixelFormat:(MTLPixelFormat)pixelFormat;

@end

NS_ASSUME_NONNULL_END
