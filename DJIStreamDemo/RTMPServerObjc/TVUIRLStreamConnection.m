//
//  TVUIRLStreamConnection.m
//  DJIStreamDemo
//

#import "TVUIRLStreamConnection.h"
#import "TVUIRLStreamingServer.h"
#import "TVUIRLStreamingServer+Internal.h"
#import "TVUIRLMediaPipeline.h"
#import "TVUIRLMediaPacket.h"
#import "TVUIRLProtocolMessage.h"
#import "TVUIRLAckMessage.h"
#import "TVUIRLMediaClock.h"
#import <QuartzCore/QuartzCore.h>

static const uint8_t kRtmpVersion = 3;

typedef NS_ENUM(NSInteger, TVUIRLConnectionHsState) {
    TVUIRLConnectionHsUninitialized,
    TVUIRLConnectionHsVersionSent,
    TVUIRLConnectionHsAckSent,
    TVUIRLConnectionHsHandshakeDone,
};

typedef NS_ENUM(NSInteger, TVUIRLChunkParserState) {
    TVUIRLChunkBasicHeaderFirstByte,
    TVUIRLChunkMessageHeaderType0,
    TVUIRLChunkMessageHeaderType1,
    TVUIRLChunkMessageHeaderType2,
    TVUIRLChunkExtendedTimestamp,
    TVUIRLChunkData,
};

@interface TVUIRLStreamConnection ()
@property (nonatomic, weak, readwrite) TVUIRLStreamingServer *server;
@property (nonatomic, strong) id<TVUIRLTransportConnection> transport;
@property (nonatomic, assign) TVUIRLConnectionHsState hsState;
@property (nonatomic, assign) TVUIRLChunkParserState chunkState;
@property (nonatomic, strong) NSMutableData *inputBuffer;
@property (nonatomic, assign) NSInteger receiveSize;
@property (nonatomic, assign) uint64_t totalBytesReceived;
@property (nonatomic, assign) uint64_t totalBytesReceivedAcked;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, TVUIRLMediaPipeline *> *pipelines;
@property (nonatomic, weak) TVUIRLMediaPipeline *currentPipeline;
@property (nonatomic, strong, readwrite) NSDate *latestReceiveTime;
@property (nonatomic, strong) TVUIRLMediaClock *mediaClock;
@property (nonatomic, assign) double basePresentationTimeStampMsValue;
@property (nonatomic, assign) BOOL hasBasePresentationTimeStamp;
@end

@implementation TVUIRLStreamConnection

- (instancetype)initWithServer:(TVUIRLStreamingServer *)server transport:(id<TVUIRLTransportConnection>)transport {
    if (self = [super init]) {
        _server = server;
        _transport = transport;
        _hsState = TVUIRLConnectionHsUninitialized;
        _chunkState = TVUIRLChunkBasicHeaderFirstByte;
        _inputBuffer = [NSMutableData data];
        _receiveSize = 1 + 1536;
        _streamKey = @"";
        _latency = 2000;
        _cameraId = [NSUUID UUID];
        _chunkSizeFromClient = 128;
        _chunkSizeToClient = 128;
        _windowAcknowledgementSize = 2500000;
        _pipelines = [NSMutableDictionary dictionary];
        _latestReceiveTime = [NSDate date];
        _mediaClock = [[TVUIRLMediaClock alloc] initWithTargetLatency:2.0];
        _lifecycle = TVUIRLConnectionLifecycleIdle;
    }
    return self;
}

- (void)start {
    self.lifecycle = TVUIRLConnectionLifecycleConnecting;
    __weak typeof(self) weakSelf = self;
    [self.transport startWithQueue:self.server.serverQueue
                    receiveHandler:^(NSData *data) {
        [weakSelf processReceivedData:data];
    }
                    failureHandler:^(NSError * _Nullable error) {
        NSString *reason = error ? error.localizedDescription : @"Disconnected";
        [weakSelf stopInternal:reason];
    }];
}

- (void)stopWithReason:(NSString *)reason {
    NSLog(@"rtmp-server: client stopping: %@", reason);
    for (TVUIRLMediaPipeline *p in self.pipelines.allValues) {
        [p stop];
    }
    [self.pipelines removeAllObjects];
    [self.transport cancel];
    self.lifecycle = TVUIRLConnectionLifecycleIdle;
}

- (void)stopInternal:(NSString *)reason {
    if (self.lifecycle == TVUIRLConnectionLifecycleIdle) return;
    [self.server connectionDidDisconnect:self reason:reason];
}

- (void)processReceivedData:(NSData *)data {
    self.totalBytesReceived += data.length;
    [self.server.bandwidthMeter addBytesTransferred:(NSInteger)data.length];
    self.latestReceiveTime = [NSDate date];
    [self.inputBuffer appendData:data];
    NSInteger offset = 0;
    while ((NSInteger)self.inputBuffer.length - offset >= self.receiveSize) {
        NSData *slice = [self.inputBuffer subdataWithRange:NSMakeRange(offset, self.receiveSize)];
        offset += self.receiveSize;
        [self handleData:slice];
    }
    if (offset > 0) {
        [self.inputBuffer replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
    }
    if (self.totalBytesReceived - self.totalBytesReceivedAcked > (uint64_t)self.windowAcknowledgementSize) {
        [self sendAck];
        self.totalBytesReceivedAcked = self.totalBytesReceived;
    }
}

- (void)handleData:(NSData *)data {
    switch (self.hsState) {
        case TVUIRLConnectionHsUninitialized:
            [self handleHandshakeC0C1:data];
            break;
        case TVUIRLConnectionHsVersionSent:
            // 不应到达：在 uninitialized → ackSent 一步切换。
            break;
        case TVUIRLConnectionHsAckSent:
            [self handleHandshakeC2];
            break;
        case TVUIRLConnectionHsHandshakeDone:
            [self handleChunkData:data];
            break;
    }
}

#pragma mark - Handshake

- (void)handleHandshakeC0C1:(NSData *)data {
    if (data.length != 1 + 1536) {
        [self stopInternal:[NSString stringWithFormat:@"Wrong length %lu in uninitialized", (unsigned long)data.length]];
        return;
    }
    const uint8_t *bytes = data.bytes;
    if (bytes[0] != kRtmpVersion) {
        [self stopInternal:[NSString stringWithFormat:@"Only RTMP version 3 supported, got %u", bytes[0]]];
        return;
    }
    // S0
    uint8_t s0 = kRtmpVersion;
    [self sendBytes:[NSData dataWithBytes:&s0 length:1]];
    // S1: 8 zeros + 1528 random
    NSMutableData *s1 = [NSMutableData dataWithLength:8];
    NSMutableData *random = [NSMutableData dataWithLength:1528];
    arc4random_buf(random.mutableBytes, 1528);
    [s1 appendData:random];
    [self sendBytes:s1];
    self.hsState = TVUIRLConnectionHsVersionSent;
    // S2: C1[0..3] + 0(4) + C1[8..]
    NSMutableData *s2 = [NSMutableData data];
    [s2 appendBytes:bytes + 1 length:4];
    uint8_t zeros[4] = {0};
    [s2 appendBytes:zeros length:4];
    [s2 appendBytes:bytes + 9 length:1528];
    [self sendBytes:s2];
    self.hsState = TVUIRLConnectionHsAckSent;
    self.receiveSize = 1536;
}

- (void)handleHandshakeC2 {
    self.hsState = TVUIRLConnectionHsHandshakeDone;
    [self requestBasicHeaderFirstByte];
}

#pragma mark - Chunk parsing

- (void)handleChunkData:(NSData *)data {
    switch (self.chunkState) {
        case TVUIRLChunkBasicHeaderFirstByte: [self handleBasicHeaderFirstByte:data]; break;
        case TVUIRLChunkMessageHeaderType0:   [self handleMessageHeaderType0:data]; break;
        case TVUIRLChunkMessageHeaderType1:   [self handleMessageHeaderType1:data]; break;
        case TVUIRLChunkMessageHeaderType2:   [self handleMessageHeaderType2:data]; break;
        case TVUIRLChunkExtendedTimestamp:    [self handleExtendedTimestamp:data]; break;
        case TVUIRLChunkData:                 [self handleChunkBody:data]; break;
    }
}

- (void)handleBasicHeaderFirstByte:(NSData *)data {
    if (data.length != 1) {
        [self stopInternal:@"Wrong length in basic header first byte"];
        return;
    }
    uint8_t firstByte = ((const uint8_t *)data.bytes)[0];
    uint8_t format = firstByte >> 6;
    uint16_t chunkStreamId = (uint16_t)(firstByte & 0x3F);
    if (chunkStreamId == 0) {
        [self stopInternal:@"Two bytes basic header is not implemented"];
        return;
    }
    if (chunkStreamId == 1) {
        [self stopInternal:@"Three bytes basic header is not implemented"];
        return;
    }
    NSNumber *key = @(chunkStreamId);
    TVUIRLMediaPipeline *p = self.pipelines[key];
    if (!p) {
        p = [[TVUIRLMediaPipeline alloc] initWithConnection:self chunkStreamId:chunkStreamId];
        self.pipelines[key] = p;
    }
    self.currentPipeline = p;
    switch (format) {
        case 0: [self requestMessageHeaderType0]; break;
        case 1: [self requestMessageHeaderType1]; break;
        case 2: [self requestMessageHeaderType2]; break;
        case 3: [self handleMessageHeaderType3]; break;
        default:
            [self stopInternal:@"Invalid chunk format"];
            break;
    }
}

static uint32_t readUInt24Be(const uint8_t *p) {
    return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
}
static uint32_t readUInt32Le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint32_t readUInt32Be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

- (void)handleMessageHeaderType0:(NSData *)data {
    if (data.length != 11) { [self stopInternal:@"Wrong length in message header type 0"]; return; }
    const uint8_t *b = data.bytes;
    self.currentPipeline.isAbsoluteTimestamp = YES;
    self.currentPipeline.messageTimestamp = readUInt24Be(b);
    self.currentPipeline.messageLength = (NSInteger)readUInt24Be(b + 3);
    self.currentPipeline.messageTypeId = b[6];
    self.currentPipeline.messageStreamId = readUInt32Le(b + 7);
    [self requestExtendedTimestampOrData];
}

- (void)handleMessageHeaderType1:(NSData *)data {
    if (data.length != 7) { [self stopInternal:@"Wrong length in message header type 1"]; return; }
    const uint8_t *b = data.bytes;
    self.currentPipeline.isAbsoluteTimestamp = NO;
    self.currentPipeline.messageTimestamp = readUInt24Be(b);
    self.currentPipeline.messageLength = (NSInteger)readUInt24Be(b + 3);
    self.currentPipeline.messageTypeId = b[6];
    [self requestExtendedTimestampOrData];
}

- (void)handleMessageHeaderType2:(NSData *)data {
    if (data.length != 3) { [self stopInternal:@"Wrong length in message header type 2"]; return; }
    const uint8_t *b = data.bytes;
    self.currentPipeline.isAbsoluteTimestamp = NO;
    self.currentPipeline.messageTimestamp = readUInt24Be(b);
    [self requestExtendedTimestampOrData];
}

- (void)handleMessageHeaderType3 {
    if (self.currentPipeline.extendedTimestampPresentInType3) {
        [self requestExtendedTimestamp];
    } else {
        [self requestChunkData];
    }
}

- (void)handleExtendedTimestamp:(NSData *)data {
    if (data.length != 4) { [self stopInternal:@"Wrong length in extended timestamp"]; return; }
    self.currentPipeline.messageTimestamp = readUInt32Be(data.bytes);
    [self requestChunkData];
}

- (void)handleChunkBody:(NSData *)data {
    [self.currentPipeline appendChunkData:data];
    [self requestBasicHeaderFirstByte];
}

#pragma mark - State transitions (set receiveSize)

- (void)requestBasicHeaderFirstByte { self.chunkState = TVUIRLChunkBasicHeaderFirstByte; self.receiveSize = 1; }
- (void)requestMessageHeaderType0   { self.chunkState = TVUIRLChunkMessageHeaderType0;   self.receiveSize = 11; }
- (void)requestMessageHeaderType1   { self.chunkState = TVUIRLChunkMessageHeaderType1;   self.receiveSize = 7; }
- (void)requestMessageHeaderType2   { self.chunkState = TVUIRLChunkMessageHeaderType2;   self.receiveSize = 3; }
- (void)requestExtendedTimestamp    { self.chunkState = TVUIRLChunkExtendedTimestamp;    self.receiveSize = 4; }
- (void)requestChunkData {
    NSInteger size = [self.currentPipeline nextChunkDataSize];
    if (size <= 0) {
        [self stopInternal:@"Unexpected data"];
        return;
    }
    self.chunkState = TVUIRLChunkData;
    self.receiveSize = size;
}

- (void)requestExtendedTimestampOrData {
    if (self.currentPipeline.messageTimestamp == 0xFFFFFF) {
        self.currentPipeline.extendedTimestampPresentInType3 = YES;
        [self requestExtendedTimestamp];
    } else {
        self.currentPipeline.extendedTimestampPresentInType3 = NO;
        [self requestChunkData];
    }
}

#pragma mark - Send

- (void)sendBytes:(NSData *)data {
    if (data.length == 0) return;
    [self.transport writeData:data];
}

- (void)sendMessagePacket:(TVUIRLMediaPacket *)packet {
    NSArray<NSData *> *chunks = [packet splitWithMaximumSize:self.chunkSizeToClient];
    for (NSData *c in chunks) {
        [self sendBytes:c];
    }
}

- (void)sendAck {
    TVUIRLAckMessage *msg = [[TVUIRLAckMessage alloc] init];
    msg.sequence = (uint32_t)(self.totalBytesReceived & 0xFFFFFFFFu);
    TVUIRLMediaPacket *packet = [[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                          chunkStreamId:TVUIRLChunkStreamIdControl
                                                                message:msg];
    [self sendMessagePacket:packet];
}

#pragma mark - Pipeline callbacks

- (void)pipelineDidProduceVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.server forwardVideoSampleBuffer:sampleBuffer];
}

- (void)pipelineDidProduceVideoImageBuffer:(CVImageBufferRef)imageBuffer {
    [self.server forwardVideoImageBuffer:imageBuffer];
}

- (void)pipelineDidProduceAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.server forwardAudioSampleBuffer:sampleBuffer];
}

- (void)pipelineDidObserveAudioPts:(double)pts {
    [self.mediaClock setLatestAudioPresentationTimeStamp:pts];
    [self updateTargetLatencies];
}

- (void)pipelineDidObserveVideoPts:(double)pts {
    [self.mediaClock setLatestVideoPresentationTimeStamp:pts];
    [self updateTargetLatencies];
}

- (void)updateTargetLatencies {
    TVUIRLMediaClockDecision decision = [self.mediaClock update];
    if (decision.hasUpdate) {
        [self.server forwardTargetVideoLatency:decision.videoTargetLatency
                                  audioLatency:decision.audioTargetLatency];
    }
}

- (double)basePresentationTimeStampMs {
    if (!self.hasBasePresentationTimeStamp) {
        self.basePresentationTimeStampMsValue = 1000.0 * CACurrentMediaTime();
        self.hasBasePresentationTimeStamp = YES;
    }
    return self.basePresentationTimeStampMsValue;
}

@end
