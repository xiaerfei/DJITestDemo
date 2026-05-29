//
//  RTMPIngestController.m
//  DJIStreamDemo
//
//  纯 C tvu_irl_streaming_server 的薄 ObjC 桥接。
//
//  桥接方式：C 回调表 + (__bridge void *)self；每个 C 回调内部 (__bridge ...)
//  转回 ObjC 并转发到原 delegate。RTMPIngestController 是单例，self 全程存活，
//  __bridge 无所有权转移，回调指针永不悬空。
//

#import "RTMPIngestController.h"
#import "TVUIRLPreviewController.h"
#import "tvu_irl_streaming_server.h"
#import "tvu_irl_stream_config.h"

@interface RTMPIngestController ()
@property (nonatomic, strong, readwrite) UIView *previewView;
@property (nonatomic, strong) TVUIRLPreviewController *previewController;
@end

@implementation RTMPIngestController {
    tvu_irl_streaming_server_t *_server;     /* owned；NULL 表示未运行 */
}

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
        _previewEnabled = YES;
    }
    return self;
}

- (void)dealloc {
    if (_server) {
        tvu_irl_streaming_server_destroy(_server);
        _server = NULL;
    }
}

#pragma mark - C → ObjC bridge callbacks

static void on_publish_start(const char *stream_key, void *user) {
    RTMPIngestController *self = (__bridge RTMPIngestController *)user;
    NSString *key = stream_key ? @(stream_key) : @"";
    NSLog(@"rtmp-ingest: publish started for '%@'", key);
    id<RTMPIngestControllerDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(rtmpIngestDidStartPublishWithStreamKey:)]) {
        [d rtmpIngestDidStartPublishWithStreamKey:key];
    }
}

static void on_publish_stop(const char *stream_key, const char *reason, void *user) {
    RTMPIngestController *self = (__bridge RTMPIngestController *)user;
    NSString *key = stream_key ? @(stream_key) : @"";
    NSString *reasonStr = reason ? @(reason) : @"";
    NSLog(@"rtmp-ingest: publish stopped '%@' (%@)", key, reasonStr);
    id<RTMPIngestControllerDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(rtmpIngestDidStopPublishWithStreamKey:reason:)]) {
        [d rtmpIngestDidStopPublishWithStreamKey:key reason:reasonStr];
    }
}

static void on_video_sample_buffer(CMSampleBufferRef sb, void *user) {
    RTMPIngestController *self = (__bridge RTMPIngestController *)user;
    if (!self.previewEnabled) return;
    [self.previewController updateSampleBuffer:sb];
}

static void on_video_image_buffer(CVImageBufferRef ib, void *user) {
    RTMPIngestController *self = (__bridge RTMPIngestController *)user;
    if (!self.previewEnabled) return;
    [self.previewController updateFrame:ib];
}

static void on_audio_sample_buffer(CMSampleBufferRef sb, void *user) {
    /* Demo 不处理音频 */
    (void)sb; (void)user;
}

static void on_stats_update(tvu_irl_bandwidth_snapshot_t snapshot, void *user) {
    /* 默认 server 暴露 updateStats（caller 主动拉），不通过 callback 推。 */
    (void)snapshot; (void)user;
}

static void on_target_latencies(double video_latency, double audio_latency, void *user) {
    /* Demo 不消费同步建议；预留接口便于将来扩展。 */
    (void)video_latency; (void)audio_latency; (void)user;
}

#pragma mark - Lifecycle

- (void)startWithPort:(uint16_t)port streamKey:(NSString *)streamKey {
    [self stop];

    /* 构造 stream_config */
    tvu_irl_stream_config_t cfg;
    tvu_irl_stream_config_init_with(&cfg, port, self.noDelay);
    tvu_irl_stream_config_add_stream(&cfg,
                                     tvu_irl_strv_from_cstr(streamKey.UTF8String ?: ""),
                                     self.latency);

    /* 构造 callbacks */
    tvu_irl_server_callbacks_t cb = {
        .on_publish_start         = on_publish_start,
        .on_publish_stop          = on_publish_stop,
        .on_video_sample_buffer   = on_video_sample_buffer,
        .on_video_image_buffer    = on_video_image_buffer,
        .on_audio_sample_buffer   = on_audio_sample_buffer,
        .on_stats_update          = on_stats_update,
        .on_target_latencies      = on_target_latencies,
        .user                     = (__bridge void *)self,
    };

    _server = tvu_irl_streaming_server_create(&cfg, cb);
    /* server 内部深拷贝了 config，原 config 销毁 */
    tvu_irl_stream_config_destroy(&cfg);

    if (!tvu_irl_streaming_server_start(_server)) {
        tvu_irl_streaming_server_destroy(_server);
        _server = NULL;
        return;
    }
    NSLog(@"rtmp-ingest: listening on port %u for key '%@' (display layer, pure C backend)",
          port, streamKey);
}

- (void)stop {
    if (_server) {
        tvu_irl_streaming_server_destroy(_server);
        _server = NULL;
    }
    [self.previewController clearFrame];
}

- (BOOL)isRunning {
    return _server != NULL;
}

- (TVUIRLBandwidthSnapshot)updateStats {
    if (!_server) {
        TVUIRLBandwidthSnapshot empty = {0, 0};
        return empty;
    }
    return tvu_irl_streaming_server_update_stats(_server);
}

- (void)setPreviewEnabled:(BOOL)enabled {
    BOOL wasEnabled = _previewEnabled;
    _previewEnabled = enabled;
    if (wasEnabled && !enabled) {
        [self.previewController clearFrame];
    }
}

@end
