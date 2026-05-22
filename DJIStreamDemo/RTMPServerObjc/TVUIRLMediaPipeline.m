//
//  TVUIRLMediaPipeline.m
//  DJIStreamDemo
//

#import "TVUIRLMediaPipeline.h"
#import "TVUIRLDJILog.h"
#import "TVUIRLStreamConnection.h"
#import "TVUIRLStreamingServer.h"
#import "TVUIRLStreamingServer+Internal.h"
#import "TVUIRLStreamConfig.h"
#import "TVUIRLProtocolMessage.h"
#import "TVUIRLAmfValue.h"
#import "TVUIRLAmfDecoder.h"
#import "TVUIRLAmfEncoder.h"
#import "TVUIRLCommandMessage.h"
#import "TVUIRLFlowControl.h"
#import "TVUIRLBandwidthConfig.h"
#import "TVUIRLWindowAckMessage.h"
#import "TVUIRLMediaPacket.h"
#import "TVUIRLVideoConfigAvc.h"
#import "TVUIRLVideoConfigHevc.h"
#import "TVUIRLAudioConfig.h"
#import "TVUIRLAudioDecoder.h"
#import "TVUIRLHardwareDecoder.h"
#import <CoreMedia/CoreMedia.h>

// FLV constants
static const uint8_t kFlvVideoCodecAvc  = 7;
static const uint8_t kFlvVideoCodecExt  = 0x0F;  // bit pattern indicating extended header
static const uint8_t kFlvFrameTypeKey   = 1;
static const uint8_t kFlvAvcPacketTypeSeq = 0;
static const uint8_t kFlvAvcPacketTypeNal = 1;
static const uint8_t kFlvVideoPacketSequenceStart = 0;
static const uint8_t kFlvVideoPacketCodedFrames   = 1;
static const uint8_t kFlvVideoPacketSequenceEnd   = 2;
static const uint8_t kFlvVideoPacketCodedFramesX  = 3;
static const uint8_t kFlvAacPacketTypeSeq = 0;
static const uint8_t kFlvAacPacketTypeRaw = 1;
static const uint8_t kFlvAudioCodecAac = 0xA;  // (control >> 4) == 10
// 4CC for HEVC: 'h','v','c','1'
static const uint32_t kFlvFourCcHevc = 0x68766331u;
// FLV tag header sizes
static const NSInteger kFlvVideoHeaderSize = 5;
static const NSInteger kFlvAudioHeaderSize = 2;

static NSString * const kRtmpServerApp = @"/live";

/// messageBody raw buffer 初始容量；控制流 / audio 小消息常驻容量。
static const NSInteger kTVUIRLMessageBodyInitCap = 4 * 1024;
/// messageBody raw buffer 上限；超过即 stopWithReason 兜底。
/// 10Mbps × 200ms 帧 + 安全余量 ≈ 256KB，2MB 远大于实际 message 上限。
static const NSInteger kTVUIRLMessageBodyMaxCap  = 2 * 1024 * 1024;

/// 消息体 raw buffer：替代原 messageBody (NSMutableData)。
/// 每个 pipeline (chunkStreamId) 一个；length 在 processMessage 后重置为 0，capacity 稳态保留。
/// 消除 ~9420 次/秒 `-[NSMutableData appendBytes:length:]` 调用的 ObjC dispatch + cluster 跳转开销。
typedef struct {
    uint8_t   *base;     ///< malloc 起点
    NSInteger  capacity; ///< 当前容量；realloc 增长（1.5x，上限 kTVUIRLMessageBodyMaxCap）
    NSInteger  length;   ///< 当前有效字节
} TVUIRLMessageBody;

@interface TVUIRLMediaPipeline () <TVUIRLHardwareDecoderDelegate, TVUIRLAudioDecoderDelegate> {
    TVUIRLMessageBody _messageBody;
}
@property (nonatomic, weak) TVUIRLStreamConnection *connection;
@property (nonatomic, assign) uint16_t chunkStreamId;
@property (nonatomic, assign) double mediaTimestamp;
@property (nonatomic, assign) double mediaTimestampZero;
@property (nonatomic, assign) double videoTimestamp;
@property (nonatomic, assign) BOOL hasMediaTimestampZero;
@property (nonatomic, assign) BOOL hasVideoTimestamp;
@property (nonatomic, strong, nullable) TVUIRLHardwareDecoder *videoDecoder;
@property (nonatomic, strong, nullable) TVUIRLAudioDecoder *audioDecoder;
@property (nonatomic, assign) CMVideoFormatDescriptionRef videoFormatDescription;
// Layer-1：DJI RTMP 原始时间戳诊断（basetime 之前）
@property (nonatomic, assign) int64_t djiAudioFrameCount;
@property (nonatomic, assign) double  djiPrevAudioTs;
@property (nonatomic, assign) int64_t djiVideoFrameCount;
@property (nonatomic, assign) double  djiPrevVideoTs;
// Layer-2：解码输出连续性诊断
@property (nonatomic, assign) CMTime  djiPrevDecodedAudioEnd;
@property (nonatomic, assign) int64_t djiDecodedAudioCount;
@property (nonatomic, assign) CMTime  djiPrevDecodedVideoEnd;
@property (nonatomic, assign) int64_t djiDecodedVideoCount;
@end

@implementation TVUIRLMediaPipeline

- (instancetype)initWithConnection:(TVUIRLStreamConnection *)connection chunkStreamId:(uint16_t)chunkStreamId {
    if (self = [super init]) {
        _connection = connection;
        _chunkStreamId = chunkStreamId;
        _messageBody.base = (uint8_t *)malloc((size_t)kTVUIRLMessageBodyInitCap);
        _messageBody.capacity = kTVUIRLMessageBodyInitCap;
        // _messageBody.length 已 zero-init
        _mediaTimestamp = 0;
        _mediaTimestampZero = -1;
        _videoTimestamp = -1;
        _isAbsoluteTimestamp = YES;
        _extendedTimestampPresentInType3 = NO;
        _djiPrevDecodedAudioEnd = kCMTimeInvalid;
        _djiPrevDecodedVideoEnd = kCMTimeInvalid;
    }
    return self;
}

- (void)dealloc {
    if (_videoFormatDescription) CFRelease(_videoFormatDescription);
    if (_messageBody.base) {
        free(_messageBody.base);
        _messageBody.base = NULL;
    }
}

- (void)stop {
    [self.videoDecoder stop];
    self.videoDecoder = nil;
}

- (NSInteger)remainingMessageBytes {
    return self.messageLength - _messageBody.length;
}

- (NSInteger)nextChunkDataSize {
    NSInteger fromClient = self.connection.chunkSizeFromClient;
    NSInteger remaining = [self remainingMessageBytes];
    return MIN(fromClient, remaining);
}

- (void)appendChunkRawBytes:(const uint8_t *)bytes length:(NSInteger)length {
    if (length <= 0) return;
    NSInteger need = _messageBody.length + length;
    if (__builtin_expect(need > _messageBody.capacity, 0)) {
        NSInteger newCap = MAX(_messageBody.capacity * 3 / 2, need);
        if (newCap > kTVUIRLMessageBodyMaxCap) {
            [self.connection stopWithReason:[NSString stringWithFormat:@"Message too large: %ld", (long)need]];
            return;
        }
        _messageBody.base = (uint8_t *)realloc(_messageBody.base, (size_t)newCap);
        _messageBody.capacity = newCap;
    }
    memcpy(_messageBody.base + _messageBody.length, bytes, (size_t)length);
    _messageBody.length += length;
    if ([self remainingMessageBytes] == 0) {
        [self processMessage];
        _messageBody.length = 0;
    }
}

- (void)processMessage {
    // Update mediaTimestamp
    if (self.isAbsoluteTimestamp) {
        self.mediaTimestamp = (double)self.messageTimestamp;
    } else {
        self.mediaTimestamp += (double)self.messageTimestamp;
    }
    if (!self.hasMediaTimestampZero) {
        self.mediaTimestampZero = self.mediaTimestamp;
        self.hasMediaTimestampZero = YES;
    }
    switch (self.messageTypeId) {
        case TVUIRLMessageTypeAmf0Command: [self processAmf0Command]; break;
        case TVUIRLMessageTypeAmf0Data:    /* ignored */ break;
        case TVUIRLMessageTypeChunkSize:   [self processChunkSize]; break;
        case TVUIRLMessageTypeWindowAck:   [self processWindowAck]; break;
        case TVUIRLMessageTypeVideo:       [self processVideo]; break;
        case TVUIRLMessageTypeAudio:       [self processAudio]; break;
        default:
            TVUIRLDJILog(@"rtmp-server: unsupported message type 0x%02x", self.messageTypeId);
            break;
    }
}

#pragma mark - AMF0 Command

- (void)processAmf0Command {
    TVUIRLStreamConnection *client = self.connection;
    if (!client) return;
    NSData *bodyData = [NSData dataWithBytesNoCopy:_messageBody.base
                                            length:_messageBody.length
                                      freeWhenDone:NO];
    TVUIRLAmfDecoder *decoder = [[TVUIRLAmfDecoder alloc] initWithData:bodyData];
    NSError *error = nil;
    NSString *commandName = [decoder decodeStringWithError:&error];
    if (error) { [client stopWithReason:[NSString stringWithFormat:@"AMF decode error %@", error]]; return; }
    int transactionId = 0;
    if (![decoder decodeInt:&transactionId error:&error]) { [client stopWithReason:[NSString stringWithFormat:@"AMF decode error %@", error]]; return; }
    NSDictionary *commandObject = [decoder decodeObjectWithError:&error];
    if (error) { [client stopWithReason:[NSString stringWithFormat:@"AMF decode error %@", error]]; return; }
    NSMutableArray<TVUIRLAmfValue *> *args = [NSMutableArray array];
    while (decoder.bytesAvailable > 0) {
        TVUIRLAmfValue *v = [decoder decodeWithError:&error];
        if (!v) break;
        [args addObject:v];
    }

    if ([commandName isEqualToString:TVUIRLCommandNameConnect]) {
        [self handleConnect:transactionId commandObject:commandObject];
    } else if ([commandName isEqualToString:TVUIRLCommandNameCreateStream]) {
        [self handleCreateStream:transactionId];
    } else if ([commandName isEqualToString:TVUIRLCommandNamePublish]) {
        [self handlePublish:transactionId arguments:args];
    } else if ([commandName isEqualToString:TVUIRLCommandNameFCPublish]
            || [commandName isEqualToString:TVUIRLCommandNameFCUnpublish]
            || [commandName isEqualToString:TVUIRLCommandNameDeleteStream]) {
        // No-op replies
    } else {
        TVUIRLDJILog(@"rtmp-server: unsupported command %@", commandName);
    }
}

- (void)handleConnect:(int)transactionId commandObject:(NSDictionary<NSString *, TVUIRLAmfValue *> *)commandObject {
    TVUIRLStreamConnection *client = self.connection;
    TVUIRLAmfValue *tcUrlValue = commandObject[@"tcUrl"];
    if (tcUrlValue.type != TVUIRLAmfValueTypeString) { [client stopWithReason:@"Stream URL missing"]; return; }
    NSURL *url = [NSURL URLWithString:tcUrlValue.stringValue];
    if (!url) { [client stopWithReason:@"Invalid stream URL"]; return; }
    if (![url.path isEqualToString:kRtmpServerApp]) { [client stopWithReason:@"Not a camera path"]; return; }

    // Send WindowAck, BWConfig, ChunkSize on control stream
    TVUIRLWindowAckMessage *winAck = [[TVUIRLWindowAckMessage alloc] initWithSize:500000];
    [client sendMessagePacket:[[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                        chunkStreamId:TVUIRLChunkStreamIdControl
                                                              message:winAck]];
    TVUIRLBandwidthConfig *bwConfig = [[TVUIRLBandwidthConfig alloc] initWithSize:10000000 limit:TVUIRLBandwidthLimitDynamic];
    [client sendMessagePacket:[[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                        chunkStreamId:TVUIRLChunkStreamIdControl
                                                              message:bwConfig]];
    TVUIRLFlowControl *fc = [[TVUIRLFlowControl alloc] initWithSize:128];
    [client sendMessagePacket:[[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                        chunkStreamId:TVUIRLChunkStreamIdControl
                                                              message:fc]];
    client.chunkSizeToClient = 128;

    NSDictionary *info = @{
        @"level": [TVUIRLAmfValue stringValue:@"status"],
        @"code": [TVUIRLAmfValue stringValue:@"NetConnection.Connect.Success"],
        @"description": [TVUIRLAmfValue stringValue:@"Connection succeeded."],
    };
    TVUIRLCommandMessage *result = [[TVUIRLCommandMessage alloc] initWithStreamId:self.messageStreamId
                                                                     transactionId:transactionId
                                                                       commandType:TVUIRLMessageTypeAmf0Command
                                                                       commandName:TVUIRLCommandNameResult
                                                                     commandObject:nil
                                                                         arguments:@[[TVUIRLAmfValue objectValue:info]]];
    [client sendMessagePacket:[[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                        chunkStreamId:self.chunkStreamId
                                                              message:result]];
}

- (void)handleCreateStream:(int)transactionId {
    TVUIRLStreamConnection *client = self.connection;
    TVUIRLCommandMessage *result = [[TVUIRLCommandMessage alloc] initWithStreamId:self.messageStreamId
                                                                     transactionId:transactionId
                                                                       commandType:TVUIRLMessageTypeAmf0Command
                                                                       commandName:TVUIRLCommandNameResult
                                                                     commandObject:nil
                                                                         arguments:@[[TVUIRLAmfValue numberValue:1]]];
    [client sendMessagePacket:[[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                        chunkStreamId:self.chunkStreamId
                                                              message:result]];
}

- (void)handlePublish:(int)transactionId arguments:(NSArray<TVUIRLAmfValue *> *)arguments {
    TVUIRLStreamConnection *client = self.connection;
    if (arguments.count == 0) { [client stopWithReason:@"Missing publish argument"]; return; }
    TVUIRLAmfValue *streamKeyValue = arguments[0];
    if (streamKeyValue.type != TVUIRLAmfValueTypeString) { [client stopWithReason:@"Stream key not a string"]; return; }
    NSString *streamKey = streamKeyValue.stringValue;
    TVUIRLStreamProfile *matched = nil;
    for (TVUIRLStreamProfile *profile in client.server.config.streams) {
        if (profile.streamKey.length > 0 && [profile.streamKey isEqualToString:streamKey]) {
            matched = profile; break;
        }
    }
    if (!matched) {
        [client stopWithReason:[NSString stringWithFormat:@"Stream key %@ not configured", streamKey]];
        return;
    }
    client.latency = matched.latency;
    client.cameraId = matched.uuid;
    client.streamKey = streamKey;
    client.lifecycle = TVUIRLConnectionLifecycleConnected;
    [client.server connectionDidComplete:client];

    NSDictionary *info = @{
        @"level": [TVUIRLAmfValue stringValue:@"status"],
        @"code": [TVUIRLAmfValue stringValue:@"NetStream.Publish.Start"],
        @"description": [TVUIRLAmfValue stringValue:@"Start publishing."],
    };
    TVUIRLCommandMessage *onStatus = [[TVUIRLCommandMessage alloc] initWithStreamId:self.messageStreamId
                                                                       transactionId:transactionId
                                                                         commandType:TVUIRLMessageTypeAmf0Command
                                                                         commandName:TVUIRLCommandNameOnStatus
                                                                       commandObject:nil
                                                                           arguments:@[[TVUIRLAmfValue objectValue:info]]];
    [client sendMessagePacket:[[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                        chunkStreamId:self.chunkStreamId
                                                              message:onStatus]];
}

#pragma mark - Control messages

- (void)processChunkSize {
    if (_messageBody.length != 4) { [self.connection stopWithReason:@"Not 4 bytes chunk size"]; return; }
    const uint8_t *b = _messageBody.base;
    uint32_t value = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    self.connection.chunkSizeFromClient = (NSInteger)value;
    TVUIRLDJILog(@"rtmp-server: chunk size from client: %u", value);
}

- (void)processWindowAck {
    if (_messageBody.length != 4) { [self.connection stopWithReason:@"Not 4 bytes window ack"]; return; }
    const uint8_t *b = _messageBody.base;
    uint32_t value = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    self.connection.windowAcknowledgementSize = (NSInteger)value;
    TVUIRLDJILog(@"rtmp-server: window ack size from client: %u", value);
}

#pragma mark - Video

- (BOOL)checkBodyAtLeast:(NSInteger)minimum {
    if ((NSInteger)_messageBody.length < minimum) {
        [self.connection stopWithReason:[NSString stringWithFormat:@"Body too short: %lu < %ld",
            (unsigned long)_messageBody.length, (long)minimum]];
        return NO;
    }
    return YES;
}

- (void)processVideo {
    if (![self checkBodyAtLeast:2]) return;
    const uint8_t *b = _messageBody.base;
    uint8_t control = b[0];
    BOOL isExHeader = (control & kFlvVideoCodecExt) == kFlvVideoCodecExt;
    if (isExHeader) {
        [self processVideoExtendedHeader:control];
    } else {
        [self processVideoDefaultHeader:control];
    }
}

- (void)processVideoDefaultHeader:(uint8_t)control {
    uint8_t codecId = control & 0x0F;
    if (codecId != kFlvVideoCodecAvc) {
        [self.connection stopWithReason:[NSString stringWithFormat:@"Unsupported video codec %u", codecId]];
        return;
    }
    if (_messageBody.length < 2) return;
    uint8_t avcPacketType = ((const uint8_t *)_messageBody.base)[1];
    if (avcPacketType == kFlvAvcPacketTypeSeq) {
        [self processAvcSequenceStart];
    } else if (avcPacketType == kFlvAvcPacketTypeNal) {
        [self processAvcCodedFrames];
    } else {
        TVUIRLDJILog(@"rtmp-server: unsupported AVC packet type %u", avcPacketType);
    }
}

- (void)processVideoExtendedHeader:(uint8_t)control {
    if (![self checkBodyAtLeast:5]) return;
    uint8_t frameType = (control >> 4) & 0x07;
    uint8_t packetType = control & 0x0F;
    const uint8_t *b = _messageBody.base;
    uint32_t fourCc = ((uint32_t)b[1] << 24) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 8) | b[4];
    if (fourCc != kFlvFourCcHevc) {
        [self.connection stopWithReason:[NSString stringWithFormat:@"Unsupported fourCC 0x%08x", fourCc]];
        return;
    }
    BOOL isKey = (frameType == kFlvFrameTypeKey);
    switch (packetType) {
        case kFlvVideoPacketSequenceStart: [self processHevcSequenceStart]; break;
        case kFlvVideoPacketCodedFrames:   [self processHevcCodedFrames:isKey withCompositionTime:YES]; break;
        case kFlvVideoPacketSequenceEnd:   [self.connection stopWithReason:@"Stream ended"]; break;
        case kFlvVideoPacketCodedFramesX:  [self processHevcCodedFrames:isKey withCompositionTime:NO]; break;
        default:
            TVUIRLDJILog(@"rtmp-server: unsupported video packet type %u", packetType);
            break;
    }
}

- (void)processAvcSequenceStart {
    if (![self checkBodyAtLeast:kFlvVideoHeaderSize]) return;
    NSData *avcC = [NSData dataWithBytesNoCopy:_messageBody.base + kFlvVideoHeaderSize
                                        length:_messageBody.length - kFlvVideoHeaderSize
                                  freeWhenDone:NO];
    TVUIRLVideoConfigAvc *config = [[TVUIRLVideoConfigAvc alloc] initWithAvcC:avcC];
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus status = [config makeFormatDescription:&desc];
    if (status == noErr) {
        if (self.videoFormatDescription) CFRelease(self.videoFormatDescription);
        self.videoFormatDescription = desc;
        [self setupVideoDecoderIfNeeded];
    } else {
        if (desc) CFRelease(desc);
        [self.connection stopWithReason:[NSString stringWithFormat:@"H.264 format desc error %d", (int)status]];
    }
}

- (void)processHevcSequenceStart {
    if (![self checkBodyAtLeast:kFlvVideoHeaderSize]) return;
    NSData *hvcC = [NSData dataWithBytesNoCopy:_messageBody.base + kFlvVideoHeaderSize
                                        length:_messageBody.length - kFlvVideoHeaderSize
                                  freeWhenDone:NO];
    TVUIRLVideoConfigHevc *config = [[TVUIRLVideoConfigHevc alloc] initWithHvcC:hvcC];
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus status = [config makeFormatDescription:&desc];
    if (status == noErr) {
        if (self.videoFormatDescription) CFRelease(self.videoFormatDescription);
        self.videoFormatDescription = desc;
        [self setupVideoDecoderIfNeeded];
    } else {
        if (desc) CFRelease(desc);
        [self.connection stopWithReason:[NSString stringWithFormat:@"H.265 format desc error %d", (int)status]];
    }
}

- (void)setupVideoDecoderIfNeeded {
    if (self.videoDecoder) return;
    if (!self.videoFormatDescription) return;
    self.videoDecoder = [[TVUIRLHardwareDecoder alloc] initWithQueue:self.connection.server.serverQueue];
    self.videoDecoder.delegate = self;
    self.videoDecoder.ptsAnchor = self.connection;
    [self.videoDecoder startWithFormatDescription:self.videoFormatDescription];
}

- (void)processAvcCodedFrames {
    if (_messageBody.length <= 9) {
        TVUIRLDJILog(@"rtmp-server: dropping short AVC packet");
        return;
    }
    const uint8_t *b = _messageBody.base;
    BOOL isKey = ((b[0] >> 4) & 0x07) == kFlvFrameTypeKey;
    int32_t compositionTime = [self readCompositionTimeAtOffset:2];
    [self emitVideoFrameKey:isKey
            compositionTime:compositionTime
                 dataOffset:kFlvVideoHeaderSize];
}

- (void)processHevcCodedFrames:(BOOL)isKey withCompositionTime:(BOOL)withCompositionTime {
    if (_messageBody.length <= 9) {
        TVUIRLDJILog(@"rtmp-server: dropping short HEVC packet");
        return;
    }
    int32_t compositionTime = withCompositionTime ? [self readCompositionTimeAtOffset:5] : 0;
    NSInteger dataOffset = withCompositionTime ? (kFlvVideoHeaderSize + 3) : kFlvVideoHeaderSize;
    [self emitVideoFrameKey:isKey
            compositionTime:compositionTime
                 dataOffset:dataOffset];
}

- (int32_t)readCompositionTimeAtOffset:(NSInteger)offset {
    if ((NSInteger)_messageBody.length < offset + 3) return 0;
    const uint8_t *b = _messageBody.base;
    int32_t v = (int32_t)(((uint32_t)b[offset] << 24)
                        | ((uint32_t)b[offset + 1] << 16)
                        | ((uint32_t)b[offset + 2] << 8));
    return v >> 8;  // arithmetic shift to sign-extend
}

- (void)emitVideoFrameKey:(BOOL)isKey
          compositionTime:(int32_t)compositionTime
               dataOffset:(NSInteger)dataOffset {
    if (!self.videoFormatDescription) return;
    if ((NSInteger)_messageBody.length <= dataOffset) return;

    NSInteger length = (NSInteger)_messageBody.length - dataOffset;
    int64_t duration = 0;
    if (self.hasVideoTimestamp) {
        duration = (int64_t)((self.mediaTimestamp - self.mediaTimestampZero) - self.videoTimestamp);
    }
    self.videoTimestamp = self.mediaTimestamp - self.mediaTimestampZero;
    self.hasVideoTimestamp = YES;
    self.connection.lastVideoRtmpTs = self.videoTimestamp;

    // Layer-1：DJI RTMP 原始时间戳（basetime 之前）
    {
        double dT = (self.djiVideoFrameCount == 0) ? 0.0 : (self.videoTimestamp - self.djiPrevVideoTs);
        // dT 正常区间 [16, 50] ms（兼容 24/30/60fps）；超出则异常
        BOOL anomaly = (self.djiVideoFrameCount > 0) && (dT > 50.0 || dT < 16.0);
        if (anomaly || self.djiVideoFrameCount == 0 || (self.djiVideoFrameCount % 30 == 0)) {
            TVUIRLDJILog(@"[DJI RTMP/V] #%lld  ts=%.0f ms  dT=%.2f ms  len=%ld  ct=%d ms%@",
                         (long long)self.djiVideoFrameCount, self.videoTimestamp, dT,
                         (long)length, (int)compositionTime, anomaly ? @"  ⚠️" : @"");
        }
        self.djiPrevVideoTs = self.videoTimestamp;
        self.djiVideoFrameCount++;
    }

    double base = [self.connection basePresentationTimeStampMs];
    int64_t pts = (int64_t)(self.videoTimestamp + base) + (int64_t)(compositionTime + self.connection.latency);
    int64_t dts = (int64_t)(self.videoTimestamp + base) + (int64_t)self.connection.latency;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(duration, 1000),
        .presentationTimeStamp = CMTimeMake(pts, 1000),
        .decodeTimeStamp = CMTimeMake(dts, 1000),
    };

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus s = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, length, kCFAllocatorDefault, NULL, 0, length,
        kCMBlockBufferAssureMemoryNowFlag, &blockBuffer);
    if (s != noErr || !blockBuffer) return;
    CMBlockBufferReplaceDataBytes((const uint8_t *)_messageBody.base + dataOffset, blockBuffer, 0, length);
    CMSampleBufferRef sampleBuffer = NULL;
    size_t sampleSize = (size_t)length;
    s = CMSampleBufferCreate(
        kCFAllocatorDefault, blockBuffer, true, NULL, NULL,
        self.videoFormatDescription, 1, 1, &timing, 1, &sampleSize, &sampleBuffer);
    CFRelease(blockBuffer);
    if (s != noErr || !sampleBuffer) return;
    [self setSampleBuffer:sampleBuffer isKey:isKey];

    double seconds = (double)pts / 1000.0;
    [self.connection pipelineDidObserveVideoPts:seconds];
    [self.videoDecoder decodeSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);
}

- (void)setSampleBuffer:(CMSampleBufferRef)sampleBuffer isKey:(BOOL)isKey {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (!attachments || CFArrayGetCount(attachments) == 0) return;
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    if (isKey) {
        CFDictionaryRemoveValue(dict, kCMSampleAttachmentKey_NotSync);
    } else {
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
    }
}

#pragma mark - Audio

- (void)processAudio {
    if (![self checkBodyAtLeast:2]) return;
    const uint8_t *b = _messageBody.base;
    uint8_t control = b[0];
    uint8_t codec = control >> 4;
    if (codec != kFlvAudioCodecAac) {
        [self.connection stopWithReason:[NSString stringWithFormat:@"Unsupported audio codec %u", codec]];
        return;
    }
    uint8_t aacPacketType = b[1];
    if (aacPacketType == kFlvAacPacketTypeSeq) {
        [self processAacSequenceStart];
    } else if (aacPacketType == kFlvAacPacketTypeRaw) {
        [self processAacRaw];
    }
}

- (void)processAacSequenceStart {
    if ((NSInteger)_messageBody.length <= kFlvAudioHeaderSize) return;
    NSData *configData = [NSData dataWithBytesNoCopy:_messageBody.base + kFlvAudioHeaderSize
                                              length:_messageBody.length - kFlvAudioHeaderSize
                                        freeWhenDone:NO];
    TVUIRLAudioConfig *config = [[TVUIRLAudioConfig alloc] initWithData:configData];
    if (!config) {
        TVUIRLDJILog(@"rtmp-server: failed to parse AudioSpecificConfig");
        return;
    }
    self.audioDecoder = [[TVUIRLAudioDecoder alloc] init];
    self.audioDecoder.delegate = self;
    self.audioDecoder.ptsAnchor = self.connection;
    [self.audioDecoder configureWithAudioConfig:config];
}

- (void)processAacRaw {
    if (!self.audioDecoder.isReady) return;
    NSInteger length = (NSInteger)_messageBody.length - kFlvAudioHeaderSize;
    if (length <= 0) return;
    NSData *aac = [NSData dataWithBytesNoCopy:_messageBody.base + kFlvAudioHeaderSize
                                       length:length
                                 freeWhenDone:NO];
    double audioTs = self.mediaTimestamp - self.mediaTimestampZero;
    double base = [self.connection basePresentationTimeStampMs];
    int64_t pts = (int64_t)(audioTs + base) + (int64_t)self.connection.latency;

    // Layer-1：DJI RTMP 原始时间戳（basetime 之前）
    {
        // AAC 1024 samples @ 48000 Hz = 21.333... ms/frame
        static const double kAacFrameDurMs = 1024.0 / 48000.0 * 1000.0;
        double dT       = (self.djiAudioFrameCount == 0) ? 0.0 : (audioTs - self.djiPrevAudioTs);
        double theoPts  = (double)self.djiAudioFrameCount * kAacFrameDurMs;   // 理论累计时间（ms）
        double drift    = audioTs - theoPts;                                   // RTMP 时钟 vs 理论 48kHz 累积偏差
        double videoTs  = self.connection.lastVideoRtmpTs;
        double avOff    = (videoTs > 0) ? (audioTs - videoTs) : NAN;
        // dT 正常区间 [10, 30] ms；超出则异常（跳帧或乱序）
        BOOL anomaly = (self.djiAudioFrameCount > 0) && (dT > 30.0 || dT < 10.0);
        if (anomaly || self.djiAudioFrameCount == 0 || (self.djiAudioFrameCount % 47 == 0)) {
            TVUIRLDJILog(@"[DJI RTMP/A] #%lld  ts=%.0f ms  dT=%.2f ms  pts=%lld ms  theo=%.1f ms  drift=%.2f ms  avOff=%.1f ms  len=%ld%@",
                         (long long)self.djiAudioFrameCount, audioTs, dT,
                         (long long)pts, theoPts, drift,
                         avOff, (long)length, anomaly ? @"  ⚠️" : @"");
        }
        self.djiPrevAudioTs = audioTs;
        self.djiAudioFrameCount++;
    }

    [self.audioDecoder decodeAacFrame:aac presentationTimeStamp:CMTimeMake(pts, 1000)];
}

#pragma mark - Decoder delegates

- (void)hardwareDecoder:(TVUIRLHardwareDecoder *)decoder didDecodeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Layer-2：视频解码输出连续性
    CMTime vPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime vDur = CMSampleBufferGetDuration(sampleBuffer);
    if (CMTIME_IS_VALID(self.djiPrevDecodedVideoEnd)) {
        double gapMs = CMTimeGetSeconds(CMTimeSubtract(vPts, self.djiPrevDecodedVideoEnd)) * 1000.0;
        BOOL anomaly = fabs(gapMs) > 10.0;
        if (anomaly || (self.djiDecodedVideoCount % 30 == 0)) {
            TVUIRLDJILog(@"[DJI DEC/V] #%lld  pts=%.3f s  gap=%.2f ms%@",
                         (long long)self.djiDecodedVideoCount,
                         CMTimeGetSeconds(vPts), gapMs, anomaly ? @"  ⚠️" : @"");
        }
    }
    CMTime vDurUsed = (CMTIME_IS_VALID(vDur) && vDur.value > 0) ? vDur : CMTimeMake(33, 1000);
    self.djiPrevDecodedVideoEnd = CMTimeAdd(vPts, vDurUsed);
    self.djiDecodedVideoCount++;

    [self.connection pipelineDidProduceVideoSampleBuffer:sampleBuffer];
}

- (void)hardwareDecoder:(TVUIRLHardwareDecoder *)decoder didDecodeImageBuffer:(CVImageBufferRef)imageBuffer {
    [self.connection pipelineDidProduceVideoImageBuffer:imageBuffer];
}

- (void)audioDecoder:(TVUIRLAudioDecoder *)decoder didDecodeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime dur = CMSampleBufferGetDuration(sampleBuffer);

    // Layer-2：音频解码输出连续性
    if (CMTIME_IS_VALID(self.djiPrevDecodedAudioEnd)) {
        double gapMs = CMTimeGetSeconds(CMTimeSubtract(pts, self.djiPrevDecodedAudioEnd)) * 1000.0;
        BOOL anomaly = fabs(gapMs) > 5.0;
        if (anomaly || (self.djiDecodedAudioCount % 47 == 0)) {
            TVUIRLDJILog(@"[DJI DEC/A] #%lld  pts=%.3f s  gap=%.2f ms%@",
                         (long long)self.djiDecodedAudioCount,
                         CMTimeGetSeconds(pts), gapMs, anomaly ? @"  ⚠️" : @"");
        }
    }
    self.djiPrevDecodedAudioEnd = CMTimeAdd(pts, dur);
    self.djiDecodedAudioCount++;

    [self.connection pipelineDidObserveAudioPts:CMTimeGetSeconds(pts)];
    [self.connection pipelineDidProduceAudioSampleBuffer:sampleBuffer];
}

@end
