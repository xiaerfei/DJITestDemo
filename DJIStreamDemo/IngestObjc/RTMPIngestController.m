//
//  RTMPIngestController.m
//  DJIStreamDemo
//

#import "RTMPIngestController.h"
#import "TVUIRLStreamingServer.h"
#import "TVUIRLStreamConfig.h"
#import "TVUIRLPreviewController.h"

@interface RTMPIngestController () <TVUIRLStreamingServerDelegate>
@property (nonatomic, strong, readwrite) UIView *previewView;
@property (nonatomic, strong) TVUIRLPreviewController *previewController;
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
        _previewController = [[TVUIRLPreviewController alloc] init];
        _previewView = _previewController.view;
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
    [self.previewController clearFrame];
}

- (BOOL)isRunning {
    return self.server != nil;
}

- (TVUIRLBandwidthSnapshot)updateStats {
    if (!self.server) {
        TVUIRLBandwidthSnapshot empty = {0, 0};
        return empty;
    }
    return [self.server updateStats];
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
        [self.previewController updateFrame:pixelBuffer];
    }
}

- (void)server:(TVUIRLStreamingServer *)server didReceiveVideoImageBuffer:(CVImageBufferRef)imageBuffer {
    [self.previewController updateFrame:imageBuffer];
}

- (void)server:(TVUIRLStreamingServer *)server didReceiveAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Demo 不处理音频
    (void)sampleBuffer;
}

@end
