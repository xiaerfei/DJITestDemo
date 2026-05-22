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
        _previewEnabled = YES;
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
    NSLog(@"rtmp-ingest: listening on port %u for key '%@' (display layer, backend=%@)",
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

// previewEnabled 关闭瞬间立即清屏, 避免显示一张冻结帧.
// BOOL 写入本身字节原子, 不需要额外锁; setter 由 UI 主线程触发, 与 server 回调线程并发安全.
- (void)setPreviewEnabled:(BOOL)enabled {
    BOOL wasEnabled = _previewEnabled;
    _previewEnabled = enabled;
    if (wasEnabled && !enabled) {
        [self.previewController clearFrame];
    }
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
    // preview 关闭时直接 return, 跳过整条渲染链路, 便于隔离测 RTMP server + 解码的纯开销.
    if (!self.previewEnabled) return;
    // sampleBuffer 直送 display layer, 避免 image buffer 二次封包.
    [self.previewController updateSampleBuffer:sampleBuffer];
}

- (void)server:(TVUIRLStreamingServer *)server didReceiveVideoImageBuffer:(CVImageBufferRef)imageBuffer {
    if (!self.previewEnabled) return;
    [self.previewController updateFrame:imageBuffer];
}

- (void)server:(TVUIRLStreamingServer *)server didReceiveAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Demo 不处理音频
    (void)sampleBuffer;
}

@end
