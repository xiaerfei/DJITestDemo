//
//  TVUIRLAudioDecoder.m
//  DJIStreamDemo
//

#import "TVUIRLAudioDecoder.h"
#import "TVUIRLAudioConfig.h"

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
        NSLog(@"rtmp-server: failed to create AAC format");
        return NO;
    }
    AVAudioFormat *pcmFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                sampleRate:aacFormat.sampleRate
                                                                  channels:aacFormat.channelCount
                                                               interleaved:aacFormat.isInterleaved];
    if (!pcmFormat) {
        NSLog(@"rtmp-server: failed to create PCM format");
        return NO;
    }
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:aacFormat toFormat:pcmFormat];
    if (!converter) {
        NSLog(@"rtmp-server: failed to create AVAudioConverter");
        return NO;
    }
    self.aacFormat = aacFormat;
    self.pcmFormat = pcmFormat;
    self.converter = converter;
    self.compressedBuffer = [[AVAudioCompressedBuffer alloc] initWithFormat:aacFormat
                                                              packetCapacity:1
                                                          maximumPacketSize:4096 * (NSInteger)aacFormat.channelCount];
    self.pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:pcmFormat frameCapacity:1024];
    return self.compressedBuffer != nil && self.pcmBuffer != nil;
}

- (void)decodeAacFrame:(NSData *)aacFrame presentationTimeStamp:(CMTime)pts {
    if (!self.converter || !self.compressedBuffer || !self.pcmBuffer) return;
    NSInteger length = (NSInteger)aacFrame.length;
    if (length <= 0) return;
    if (length > self.compressedBuffer.maximumPacketSize) {
        NSLog(@"rtmp-server: AAC packet too long: %ld > %ld", (long)length, (long)self.compressedBuffer.maximumPacketSize);
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
        NSLog(@"rtmp-server: audio decode error: %@", error);
        return;
    }
    CMSampleBufferRef sampleBuffer = [self makeSampleBufferFrom:self.pcmBuffer pts:pts];
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
