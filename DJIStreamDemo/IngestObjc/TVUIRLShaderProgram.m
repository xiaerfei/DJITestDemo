#import "TVUIRLShaderProgram.h"

@interface TVUIRLShaderProgram ()
@property (nonatomic, strong, readwrite) id<MTLDevice> device;
@property (nonatomic, strong, readwrite, nullable) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong, nullable) id<MTLLibrary> library;
@end

@implementation TVUIRLShaderProgram

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (self = [super init]) {
        _device = device;
    }
    return self;
}

- (BOOL)createPipelineWithVertexFunction:(NSString *)vertexFunctionName
                        fragmentFunction:(NSString *)fragmentFunctionName
                             pixelFormat:(MTLPixelFormat)pixelFormat {
    self.library = [self.device newDefaultLibrary];
    if (!self.library) return NO;

    return [self buildPipelineWithVertex:vertexFunctionName
                               fragment:fragmentFunctionName
                             pixelFormat:pixelFormat];
}

- (BOOL)createPipelineWithSource:(NSString *)metalSource
                   vertexFunction:(NSString *)vertexFunctionName
                 fragmentFunction:(NSString *)fragmentFunctionName
                      pixelFormat:(MTLPixelFormat)pixelFormat {
    NSError *error = nil;
    self.library = [self.device newLibraryWithSource:metalSource options:NULL error:&error];
    if (!self.library) return NO;

    return [self buildPipelineWithVertex:vertexFunctionName
                               fragment:fragmentFunctionName
                             pixelFormat:pixelFormat];
}

- (BOOL)buildPipelineWithVertex:(NSString *)vertexFunctionName
                       fragment:(NSString *)fragmentFunctionName
                    pixelFormat:(MTLPixelFormat)pixelFormat {
    id<MTLFunction> vertexFunc = [self.library newFunctionWithName:vertexFunctionName];
    id<MTLFunction> fragmentFunc = [self.library newFunctionWithName:fragmentFunctionName];
    if (!vertexFunc || !fragmentFunc) return NO;

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertexFunc;
    desc.fragmentFunction = fragmentFunc;
    desc.colorAttachments[0].pixelFormat = pixelFormat;

    NSError *error = nil;
    self.pipelineState = [self.device newRenderPipelineStateWithDescriptor:desc error:&error];
    return self.pipelineState != nil;
}

@end
