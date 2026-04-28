//
//  TVUIRLMediaPipeline.m
//  DJIStreamDemo
//

#import "TVUIRLMediaPipeline.h"
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

@interface TVUIRLMediaPipeline () <TVUIRLHardwareDecoderDelegate, TVUIRLAudioDecoderDelegate>
@property (nonatomic, weak) TVUIRLStreamConnection *connection;
@property (nonatomic, assign) uint16_t chunkStreamId;
@property (nonatomic, strong) NSMutableData *messageBody;
@property (nonatomic, assign) double mediaTimestamp;
@property (nonatomic, assign) double mediaTimestampZero;
@property (nonatomic, assign) double videoTimestamp;
@property (nonatomic, assign) BOOL hasMediaTimestampZero;
@property (nonatomic, assign) BOOL hasVideoTimestamp;
@property (nonatomic, strong, nullable) TVUIRLHardwareDecoder *videoDecoder;
@property (nonatomic, strong, nullable) TVUIRLAudioDecoder *audioDecoder;
@property (nonatomic, assign) CMVideoFormatDescriptionRef videoFormatDescription;
@end

@implementation TVUIRLMediaPipeline

- (instancetype)initWithConnection:(TVUIRLStreamConnection *)connection chunkStreamId:(uint16_t)chunkStreamId {
    if (self = [super init]) {
        _connection = connection;
        _chunkStreamId = chunkStreamId;
        _messageBody = [NSMutableData data];
        _mediaTimestamp = 0;
        _mediaTimestampZero = -1;
        _videoTimestamp = -1;
        _isAbsoluteTimestamp = YES;
        _extendedTimestampPresentInType3 = NO;
    }
    return self;
}

- (void)dealloc {
    if (_videoFormatDescription) CFRelease(_videoFormatDescription);
}

- (void)stop {
    [self.videoDecoder stop];
    self.videoDecoder = nil;
}

- (NSInteger)remainingMessageBytes {
    return self.messageLength - (NSInteger)self.messageBody.length;
}

- (NSInteger)nextChunkDataSize {
    NSInteger fromClient = self.connection.chunkSizeFromClient;
    NSInteger remaining = [self remainingMessageBytes];
    return MIN(fromClient, remaining);
}

- (void)appendChunkData:(NSData *)data {
    [self.messageBody appendData:data];
    if ([self remainingMessageBytes] == 0) {
        [self processMessage];
        [self.messageBody setLength:0];
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
            NSLog(@"rtmp-server: unsupported message type 0x%02x", self.messageTypeId);
            break;
    }
}

#pragma mark - AMF0 Command

- (void)processAmf0Command {
    TVUIRLStreamConnection *client = self.connection;
    if (!client) return;
    TVUIRLAmfDecoder *decoder = [[TVUIRLAmfDecoder alloc] initWithData:self.messageBody];
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
        NSLog(@"rtmp-server: unsupported command %@", commandName);
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
    TVUIRLFlowControl *fc = [[TVUIRLFlowControl alloc] initWithSize:65536];
    [client sendMessagePacket:[[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                        chunkStreamId:TVUIRLChunkStreamIdControl
                                                              message:fc]];
    client.chunkSizeToClient = 65536;

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
    if (self.messageBody.length != 4) { [self.connection stopWithReason:@"Not 4 bytes chunk size"]; return; }
    const uint8_t *b = self.messageBody.bytes;
    uint32_t value = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    self.connection.chunkSizeFromClient = (NSInteger)value;
    NSLog(@"rtmp-server: chunk size from client: %u", value);
}

- (void)processWindowAck {
    if (self.messageBody.length != 4) { [self.connection stopWithReason:@"Not 4 bytes window ack"]; return; }
    const uint8_t *b = self.messageBody.bytes;
    uint32_t value = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    self.connection.windowAcknowledgementSize = (NSInteger)value;
    NSLog(@"rtmp-server: window ack size from client: %u", value);
}

#pragma mark - Video

- (BOOL)checkBodyAtLeast:(NSInteger)minimum {
    if ((NSInteger)self.messageBody.length < minimum) {
        [self.connection stopWithReason:[NSString stringWithFormat:@"Body too short: %lu < %ld",
            (unsigned long)self.messageBody.length, (long)minimum]];
        return NO;
    }
    return YES;
}

- (void)processVideo {
    if (![self checkBodyAtLeast:2]) return;
    const uint8_t *b = self.messageBody.bytes;
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
    if (self.messageBody.length < 2) return;
    uint8_t avcPacketType = ((const uint8_t *)self.messageBody.bytes)[1];
    if (avcPacketType == kFlvAvcPacketTypeSeq) {
        [self processAvcSequenceStart];
    } else if (avcPacketType == kFlvAvcPacketTypeNal) {
        [self processAvcCodedFrames];
    } else {
        NSLog(@"rtmp-server: unsupported AVC packet type %u", avcPacketType);
    }
}

- (void)processVideoExtendedHeader:(uint8_t)control {
    if (![self checkBodyAtLeast:5]) return;
    uint8_t frameType = (control >> 4) & 0x07;
    uint8_t packetType = control & 0x0F;
    const uint8_t *b = self.messageBody.bytes;
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
            NSLog(@"rtmp-server: unsupported video packet type %u", packetType);
            break;
    }
}

- (void)processAvcSequenceStart {
    if (![self checkBodyAtLeast:kFlvVideoHeaderSize]) return;
    NSData *avcC = [self.messageBody subdataWithRange:NSMakeRange(kFlvVideoHeaderSize,
                                                                 self.messageBody.length - kFlvVideoHeaderSize)];
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
    NSData *hvcC = [self.messageBody subdataWithRange:NSMakeRange(kFlvVideoHeaderSize,
                                                                 self.messageBody.length - kFlvVideoHeaderSize)];
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
    [self.videoDecoder startWithFormatDescription:self.videoFormatDescription];
}

- (void)processAvcCodedFrames {
    if (self.messageBody.length <= 9) {
        NSLog(@"rtmp-server: dropping short AVC packet");
        return;
    }
    const uint8_t *b = self.messageBody.bytes;
    BOOL isKey = ((b[0] >> 4) & 0x07) == kFlvFrameTypeKey;
    int32_t compositionTime = [self readCompositionTimeAtOffset:2];
    [self emitVideoFrameKey:isKey
            compositionTime:compositionTime
                 dataOffset:kFlvVideoHeaderSize];
}

- (void)processHevcCodedFrames:(BOOL)isKey withCompositionTime:(BOOL)withCompositionTime {
    if (self.messageBody.length <= 9) {
        NSLog(@"rtmp-server: dropping short HEVC packet");
        return;
    }
    int32_t compositionTime = withCompositionTime ? [self readCompositionTimeAtOffset:5] : 0;
    NSInteger dataOffset = withCompositionTime ? (kFlvVideoHeaderSize + 3) : kFlvVideoHeaderSize;
    [self emitVideoFrameKey:isKey
            compositionTime:compositionTime
                 dataOffset:dataOffset];
}

- (int32_t)readCompositionTimeAtOffset:(NSInteger)offset {
    if ((NSInteger)self.messageBody.length < offset + 3) return 0;
    const uint8_t *b = self.messageBody.bytes;
    int32_t v = (int32_t)(((uint32_t)b[offset] << 24)
                        | ((uint32_t)b[offset + 1] << 16)
                        | ((uint32_t)b[offset + 2] << 8));
    return v >> 8;  // arithmetic shift to sign-extend
}

- (void)emitVideoFrameKey:(BOOL)isKey
          compositionTime:(int32_t)compositionTime
               dataOffset:(NSInteger)dataOffset {
    if (!self.videoFormatDescription) return;
    if ((NSInteger)self.messageBody.length <= dataOffset) return;

    NSInteger length = (NSInteger)self.messageBody.length - dataOffset;
    int64_t duration = 0;
    if (self.hasVideoTimestamp) {
        duration = (int64_t)((self.mediaTimestamp - self.mediaTimestampZero) - self.videoTimestamp);
    }
    self.videoTimestamp = self.mediaTimestamp - self.mediaTimestampZero;
    self.hasVideoTimestamp = YES;
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
    CMBlockBufferReplaceDataBytes((const uint8_t *)self.messageBody.bytes + dataOffset, blockBuffer, 0, length);
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
    const uint8_t *b = self.messageBody.bytes;
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
    if ((NSInteger)self.messageBody.length <= kFlvAudioHeaderSize) return;
    NSData *configData = [self.messageBody subdataWithRange:NSMakeRange(kFlvAudioHeaderSize,
                                                                       self.messageBody.length - kFlvAudioHeaderSize)];
    TVUIRLAudioConfig *config = [[TVUIRLAudioConfig alloc] initWithData:configData];
    if (!config) {
        NSLog(@"rtmp-server: failed to parse AudioSpecificConfig");
        return;
    }
    self.audioDecoder = [[TVUIRLAudioDecoder alloc] init];
    self.audioDecoder.delegate = self;
    [self.audioDecoder configureWithAudioConfig:config];
}

- (void)processAacRaw {
    if (!self.audioDecoder.isReady) return;
    NSInteger length = (NSInteger)self.messageBody.length - kFlvAudioHeaderSize;
    if (length <= 0) return;
    NSData *aac = [self.messageBody subdataWithRange:NSMakeRange(kFlvAudioHeaderSize, length)];
    double audioTs = self.mediaTimestamp - self.mediaTimestampZero;
    double base = [self.connection basePresentationTimeStampMs];
    int64_t pts = (int64_t)(audioTs + base) + (int64_t)self.connection.latency;
    [self.audioDecoder decodeAacFrame:aac presentationTimeStamp:CMTimeMake(pts, 1000)];
}

#pragma mark - Decoder delegates

- (void)hardwareDecoder:(TVUIRLHardwareDecoder *)decoder didDecodeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.connection pipelineDidProduceVideoSampleBuffer:sampleBuffer];
}

- (void)hardwareDecoder:(TVUIRLHardwareDecoder *)decoder didDecodeImageBuffer:(CVImageBufferRef)imageBuffer {
    [self.connection pipelineDidProduceVideoImageBuffer:imageBuffer];
}

- (void)audioDecoder:(TVUIRLAudioDecoder *)decoder didDecodeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    [self.connection pipelineDidObserveAudioPts:CMTimeGetSeconds(pts)];
    [self.connection pipelineDidProduceAudioSampleBuffer:sampleBuffer];
}

@end
