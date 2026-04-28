//
//  RTMPIngestController.m
//  DJIStreamDemo
//

#import "RTMPIngestController.h"
#import "DJIStreamDemo-Swift.h"  // 引入 Swift 端 MetalPreviewView
#import "TVUIRLStreamingServer.h"
#import "TVUIRLStreamConfig.h"

@interface RTMPIngestController () <TVUIRLStreamingServerDelegate>
@property (nonatomic, strong, readwrite) UIView *previewView;
@property (nonatomic, strong) MetalPreviewView *preview;
@property (nonatomic, strong, nullable) TVUIRLStreamingServer *server;
@end

@implementation RTMPIngestController

+ (instancetype)shared {
    static RTMPIngestController *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[RTMPIngestController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _preview = [[MetalPreviewView alloc] initWithFrame:CGRectZero device:nil];
        _previewView = _preview;
        _latency = 0;
        _noDelay = YES;
        _frameQueueSize = 3;
        _backend = TVUIRLTransportBackendNetwork;
    }
    return self;
}

- (void)startWithPort:(uint16_t)port streamKey:(NSString *)streamKey {
    [self stop];
    TVUIRLStreamProfile *profile = [[TVUIRLStreamProfile alloc] initWithStreamKey:streamKey latency:self.latency];
    TVUIRLStreamConfig *config = [[TVUIRLStreamConfig alloc] initWithPort:port
                                                                  streams:@[profile]
                                                                  noDelay:self.noDelay];
    TVUIRLStreamingServer *server = [[TVUIRLStreamingServer alloc] initWithConfig:config backend:self.backend];
    server.delegate = self;
    self.server = server;
    [server start];
    NSLog(@"rtmp-ingest: listening on port %u for key '%@' (Metal renderer, backend=%@)",
          port, streamKey, [TVUIRLTransportFactory nameForBackend:self.backend]);
}

- (void)stop {
    [self.server stop];
    self.server = nil;
    [self.preview clearFrame];
}

- (BOOL)isRunning {
    return self.server != nil;
}

#pragma mark - TVUIRLStreamingServerDelegate

- (void)server:(TVUIRLStreamingServer *)server didStartPublishingStream:(NSString *)streamKey {
    NSLog(@"rtmp-ingest: publish started for '%@'", streamKey);
    if ([self.delegate respondsToSelector:@selector(rtmpIngestDidStartPublishWithStreamKey:)]) {
        [self.delegate rtmpIngestDidStartPublishWithStreamKey:streamKey];
    }
}

- (void)server:(TVUIRLStreamingServer *)server didStopPublishingStream:(NSString *)streamKey reason:(NSString *)reason {
    NSLog(@"rtmp-ingest: publish stopped '%@' (%@)", streamKey, reason);
    if ([self.delegate respondsToSelector:@selector(rtmpIngestDidStopPublishWithStreamKey:reason:)]) {
        [self.delegate rtmpIngestDidStopPublishWithStreamKey:streamKey reason:reason];
    }
}

- (void)server:(TVUIRLStreamingServer *)server didReceiveVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // 优先使用 zero-copy image buffer 路径；这里收到 CMSampleBuffer 时再 fallback 解出 CVPixelBuffer
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer) {
        [self.preview updateFrame:pixelBuffer];
    }
}

- (void)server:(TVUIRLStreamingServer *)server didReceiveVideoImageBuffer:(CVImageBufferRef)imageBuffer {
    [self.preview updateFrame:imageBuffer];
}

- (void)server:(TVUIRLStreamingServer *)server didReceiveAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Demo 不处理音频
    (void)sampleBuffer;
}

@end
