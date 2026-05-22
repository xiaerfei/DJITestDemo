//
//  TVUIRLStreamingServer.m
//  DJIStreamDemo
//

#import "TVUIRLStreamingServer.h"
#import "TVUIRLDJILog.h"
#import "TVUIRLStreamingServer+Internal.h"
#import "TVUIRLStreamConnection.h"

@interface TVUIRLStreamingServer ()
@property (nonatomic, copy, readwrite) TVUIRLStreamConfig *config;
@property (nonatomic, assign, readwrite) TVUIRLTransportBackend backend;
@property (nonatomic, strong) NSMutableArray<TVUIRLStreamConnection *> *connections;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) TVUIRLBandwidthMeter *meter;
@property (nonatomic, strong) dispatch_source_t periodicTimer;
@property (nonatomic, strong, nullable) id<TVUIRLTransportListener> listener;
@end

@implementation TVUIRLStreamingServer

- (instancetype)initWithConfig:(TVUIRLStreamConfig *)config {
    return [self initWithConfig:config backend:TVUIRLTransportBackendNetwork];
}

- (instancetype)initWithConfig:(TVUIRLStreamConfig *)config backend:(TVUIRLTransportBackend)backend {
    if (self = [super init]) {
        _config = [[TVUIRLStreamConfig alloc] initWithPort:config.port streams:config.streams noDelay:config.noDelay];
        _backend = backend;
        _connections = [NSMutableArray array];
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _queue = dispatch_queue_create("com.tvu.rtmp-server", attr);
        _meter = [[TVUIRLBandwidthMeter alloc] init];
    }
    return self;
}

- (dispatch_queue_t)serverQueue { return self.queue; }
- (TVUIRLBandwidthMeter *)bandwidthMeter { return self.meter; }

- (void)start {
    dispatch_async(self.queue, ^{
        [self setupListener];
        [self setupPeriodicTimer];
    });
}

- (void)stop {
    // dispatch_sync 保证 stop 返回前所有连接已关闭、listener 已取消，彻底防止旧 server
    // 在 startWithPort: 后继续向 RTMPIngestController 转发音视频。
    // 调用方必须从 server 串行队列以外的线程调用，否则死锁。
    dispatch_sync(self.queue, ^{
        for (TVUIRLStreamConnection *c in self.connections) {
            [c stopWithReason:@"Server stop"];
        }
        [self.connections removeAllObjects];
        [self.listener cancel];
        self.listener = nil;
        if (self.periodicTimer) {
            dispatch_source_cancel(self.periodicTimer);
            self.periodicTimer = nil;
        }
    });
}

- (BOOL)isStreamConnected:(NSString *)streamKey {
    __block BOOL connected = NO;
    dispatch_sync(self.queue, ^{
        for (TVUIRLStreamConnection *c in self.connections) {
            if ([c.streamKey isEqualToString:streamKey]) { connected = YES; break; }
        }
    });
    return connected;
}

- (NSInteger)numberOfClients {
    __block NSInteger n = 0;
    dispatch_sync(self.queue, ^{ n = self.connections.count; });
    return n;
}

- (TVUIRLBandwidthSnapshot)updateStats {
    __block TVUIRLBandwidthSnapshot snap;
    dispatch_sync(self.queue, ^{ snap = [self.meter update]; });
    return snap;
}

#pragma mark - Listener

- (void)setupListener {
    id<TVUIRLTransportListener> listener = [TVUIRLTransportFactory listenerForBackend:self.backend];
    self.listener = listener;
    __weak typeof(self) weakSelf = self;
    NSError *error = nil;
    BOOL ok = [listener startOnPort:self.config.port
                              queue:self.queue
                            noDelay:self.config.noDelay
              newConnectionHandler:^(id<TVUIRLTransportConnection> connection) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        TVUIRLStreamConnection *streamConn = [[TVUIRLStreamConnection alloc] initWithServer:self_ transport:connection];
        [self_.connections addObject:streamConn];
        [streamConn start];
        TVUIRLDJILog(@"[leak-check] new connection, total active=%lu", (unsigned long)self_.connections.count);
    }
                              error:&error];
    if (!ok) {
        TVUIRLDJILog(@"rtmp-server[%@]: failed to start listener on port %u: %@",
              [TVUIRLTransportFactory nameForBackend:self.backend],
              (unsigned)self.config.port,
              error);
    } else {
        TVUIRLDJILog(@"rtmp-server[%@]: listening on port %u",
              [TVUIRLTransportFactory nameForBackend:self.backend],
              (unsigned)self.config.port);
    }
}

#pragma mark - Periodic timer

- (void)setupPeriodicTimer {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{ [weakSelf periodicTick]; });
    dispatch_resume(timer);
    self.periodicTimer = timer;
}

- (void)periodicTick {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSMutableArray *toRemove = [NSMutableArray array];
    for (TVUIRLStreamConnection *c in self.connections) {
        if (now - c.latestReceiveAbsTime > 10.0) {
            [toRemove addObject:c];
        }
    }
    for (TVUIRLStreamConnection *c in toRemove) {
        [self connectionDidDisconnect:c reason:@"Receive timeout"];
    }
}

#pragma mark - Internal API

- (void)connectionDidComplete:(TVUIRLStreamConnection *)connection {
    NSMutableArray *newConnections = [NSMutableArray array];
    NSString *streamKey = connection.streamKey;
    for (TVUIRLStreamConnection *c in self.connections) {
        if (c != connection && [c.streamKey isEqualToString:streamKey]) {
            NSString *reason = @"Same stream key";
            if ([self.delegate respondsToSelector:@selector(server:didStopPublishingStream:reason:)]) {
                [self.delegate server:self didStopPublishingStream:streamKey reason:reason];
            }
            [c stopWithReason:reason];
        } else {
            [newConnections addObject:c];
        }
    }
    [self.connections setArray:newConnections];
    if ([self.delegate respondsToSelector:@selector(server:didStartPublishingStream:)]) {
        [self.delegate server:self didStartPublishingStream:streamKey];
    }
}

- (void)connectionDidDisconnect:(TVUIRLStreamConnection *)connection reason:(NSString *)reason {
    [connection stopWithReason:reason];
    [self.connections removeObject:connection];
    if (connection.streamKey.length > 0
        && [self.delegate respondsToSelector:@selector(server:didStopPublishingStream:reason:)]) {
        [self.delegate server:self didStopPublishingStream:connection.streamKey reason:reason];
    }
}

- (void)forwardVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if ([self.delegate respondsToSelector:@selector(server:didReceiveVideoSampleBuffer:)]) {
        [self.delegate server:self didReceiveVideoSampleBuffer:sampleBuffer];
    }
}

- (void)forwardVideoImageBuffer:(CVImageBufferRef)imageBuffer {
    if ([self.delegate respondsToSelector:@selector(server:didReceiveVideoImageBuffer:)]) {
        [self.delegate server:self didReceiveVideoImageBuffer:imageBuffer];
    }
}

- (void)forwardAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if ([self.delegate respondsToSelector:@selector(server:didReceiveAudioSampleBuffer:)]) {
        [self.delegate server:self didReceiveAudioSampleBuffer:sampleBuffer];
    }
}

- (void)forwardTargetVideoLatency:(double)videoLatency audioLatency:(double)audioLatency {
    if ([self.delegate respondsToSelector:@selector(server:didUpdateTargetVideoLatency:audioLatency:)]) {
        [self.delegate server:self didUpdateTargetVideoLatency:videoLatency audioLatency:audioLatency];
    }
}

@end
