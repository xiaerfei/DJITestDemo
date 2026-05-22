//
//  TVUIRLAudioDecoder.m
//  DJIStreamDemo
//

#import "TVUIRLAudioDecoder.h"
#import "TVUIRLDJILog.h"
#import "TVUIRLAudioConfig.h"

// 从 TVUIRL 主工程 TVUAudioEncoderManager.h 抽出的输出格式常量.
// Demo 不依赖主工程音频编码器, AAC→PCM 解码后由上层 ingest controller 丢弃,
// 此处保留同样的 48k/Stereo/Int16 目标格式以贴近真实路径.
static int const kTVUAudioEncoderStereoChannel = 2;
static int const kTVUAudioEncoderSampleRate = 48000;

@interface TVUIRLAudioDecoder ()
@property (nonatomic, strong, nullable) AVAudioFormat *aacFormat;
@property (nonatomic, strong, nullable) AVAudioFormat *pcmFormat;
@property (nonatomic, strong, nullable) AVAudioCompressedBuffer *compressedBuffer;
@property (nonatomic, strong, nullable) AVAudioPCMBuffer *pcmBuffer;
@property (nonatomic, strong, nullable) AVAudioConverter *converter;
@end

@implementation TVUIRLAudioDecoder

- (instancetype)init {
    return [super init];
}

- (BOOL)isReady {
    return self.converter != nil;
}

- (BOOL)configureWithAudioConfig:(TVUIRLAudioConfig *)config {
    AVAudioFormat *aacFormat = [config avAudioFormat];
    if (!aacFormat) {
        TVUIRLDJILog(@"rtmp-server: failed to create AAC format");
        return NO;
    }
    // PCM 输出格式钉死为 TVU encoder 期望的 48kHz / stereo / Int16 / interleaved。
    // AVAudioConverter 一次性完成 AAC 解码 + 重采样 + 声道适配，下游 RTMPIngestController
    // 直接拿到目标格式 PCM，不需要再做 PCM→PCM 转换。
    AVAudioFormat *pcmFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                sampleRate:kTVUAudioEncoderSampleRate
                                                                  channels:kTVUAudioEncoderStereoChannel
                                                               interleaved:YES];
    if (!pcmFormat) {
        TVUIRLDJILog(@"rtmp-server: failed to create PCM format");
        return NO;
    }
    static NSString * const kAacObjectTypeNames[] = {
        @"Unknown", @"AAC-Main", @"AAC-LC", @"AAC-SSR", @"AAC-LTP",
        @"HE-AAC(SBR)", @"AAC-Scalable", @"TwinVQ", @"CELP", @"HVXC", @"Opus",
    };
    NSUInteger typeIdx = (NSUInteger)config.objectType;
    NSString *typeName = typeIdx < sizeof(kAacObjectTypeNames)/sizeof(kAacObjectTypeNames[0])
        ? kAacObjectTypeNames[typeIdx] : @"?";
    TVUIRLDJILog(@"rtmp-server: AAC type=%@ sampleRate=%.0f Hz channels=%u"
                 @" (no bit-depth in compressed format) → PCM 48000 Hz stereo Int16",
                 typeName, aacFormat.sampleRate, (unsigned)aacFormat.channelCount);
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:aacFormat toFormat:pcmFormat];
    if (!converter) {
        TVUIRLDJILog(@"rtmp-server: failed to create AVAudioConverter");
        return NO;
    }
    self.aacFormat = aacFormat;
    self.pcmFormat = pcmFormat;
    self.converter = converter;
    self.compressedBuffer = [[AVAudioCompressedBuffer alloc] initWithFormat:aacFormat
                                                              packetCapacity:1
                                                          maximumPacketSize:4096 * (NSInteger)aacFormat.channelCount];
    // AAC 每帧固定 1024 input samples，重采样到 48kHz 后输出帧数按比例放大。
    // 例: 8kHz 源 → 1024 × 48/8 = 6144；44.1kHz 源 → ≈1115。+16 留 SRC 边界裕量。
    AVAudioFrameCount frameCapacity =
        (AVAudioFrameCount)ceil(1024.0 * (double)kTVUAudioEncoderSampleRate / aacFormat.sampleRate) + 16;
    self.pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:pcmFormat frameCapacity:frameCapacity];
    return self.compressedBuffer != nil && self.pcmBuffer != nil;
}

- (void)decodeAacFrame:(NSData *)aacFrame presentationTimeStamp:(CMTime)pts {
    if (!self.converter || !self.compressedBuffer || !self.pcmBuffer) return;
    NSInteger length = (NSInteger)aacFrame.length;
    if (length <= 0) return;
    if (length > self.compressedBuffer.maximumPacketSize) {
        TVUIRLDJILog(@"rtmp-server: AAC packet too long: %ld > %ld", (long)length, (long)self.compressedBuffer.maximumPacketSize);
        return;
    }
    AudioStreamPacketDescription *packetDesc = self.compressedBuffer.packetDescriptions;
    if (packetDesc) {
        packetDesc->mStartOffset = 0;
        packetDesc->mVariableFramesInPacket = 0;
        packetDesc->mDataByteSize = (UInt32)length;
    }
    self.compressedBuffer.packetCount = 1;
    self.compressedBuffer.byteLength = (UInt32)length;
    memcpy(self.compressedBuffer.data, aacFrame.bytes, (size_t)length);

    NSError *error = nil;
    __block AVAudioCompressedBuffer *input = self.compressedBuffer;
    __block BOOL provided = NO;
    AVAudioConverterOutputStatus result =
        [self.converter convertToBuffer:self.pcmBuffer
                                  error:&error
                     withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets,
                                                                  AVAudioConverterInputStatus * _Nonnull outStatus) {
        if (provided) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        provided = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return input;
    }];
    if (result == AVAudioConverterOutputStatus_Error || error) {
        TVUIRLDJILog(@"rtmp-server: audio decode error: %@", error);
        return;
    }
    // 解码出口重锚 PTS：把"流内 PTS"折回到 host time 域。无 anchor 时回退原 PTS（行为与改前一致）。
    // anchor 返回 kCMTimeInvalid 表示 video basetime 未就绪要求丢弃该音频帧；上层 IDR 等待
    // 窗口里的开播过渡音频，可丢。
    CMTime remappedPts = pts;
    id<TVUIRLDecodedPtsAnchor> anchor = self.ptsAnchor;
    if (anchor) {
        remappedPts = [anchor remapAudioDecodedPts:pts];
        if (!CMTIME_IS_VALID(remappedPts)) {
            return;
        }
    }
    CMSampleBufferRef sampleBuffer = [self makeSampleBufferFrom:self.pcmBuffer pts:remappedPts];
    if (!sampleBuffer) return;
    if ([self.delegate respondsToSelector:@selector(audioDecoder:didDecodeSampleBuffer:)]) {
        [self.delegate audioDecoder:self didDecodeSampleBuffer:sampleBuffer];
    }
    CFRelease(sampleBuffer);
}

- (CMSampleBufferRef)makeSampleBufferFrom:(AVAudioPCMBuffer *)pcm pts:(CMTime)pts {
    AVAudioFormat *format = pcm.format;
    const AudioStreamBasicDescription *asbd = format.streamDescription;
    if (!asbd) return NULL;
    CMAudioFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMAudioFormatDescriptionCreate(
        kCFAllocatorDefault, asbd, 0, NULL, 0, NULL, NULL, &formatDesc);
    if (status != noErr || !formatDesc) return NULL;

    AVAudioFrameCount frameLength = pcm.frameLength;
    if (frameLength == 0) {
        CFRelease(formatDesc);
        return NULL;
    }
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMAudioSampleBufferCreateWithPacketDescriptions(
        kCFAllocatorDefault,
        NULL,
        false,
        NULL, NULL,
        formatDesc,
        (CMItemCount)frameLength,
        pts,
        NULL,
        &sampleBuffer);
    if (status != noErr || !sampleBuffer) {
        CFRelease(formatDesc);
        return NULL;
    }
    const AudioBufferList *abl = pcm.audioBufferList;
    status = CMSampleBufferSetDataBufferFromAudioBufferList(
        sampleBuffer, kCFAllocatorDefault, kCFAllocatorDefault, 0, abl);
    CFRelease(formatDesc);
    if (status != noErr) {
        CFRelease(sampleBuffer);
        return NULL;
    }
    return sampleBuffer;
}

@end
