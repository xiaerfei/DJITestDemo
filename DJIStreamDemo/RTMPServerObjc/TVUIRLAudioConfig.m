//
//  TVUIRLAudioConfig.m
//  DJIStreamDemo
//

#import "TVUIRLAudioConfig.h"

static Float64 sampleRateFromIndex(uint8_t freq) {
    switch (freq) {
        case 0:  return 96000;
        case 1:  return 88200;
        case 2:  return 64000;
        case 3:  return 48000;
        case 4:  return 44100;
        case 5:  return 32000;
        case 6:  return 24000;
        case 7:  return 22050;
        case 8:  return 16000;
        case 9:  return 12000;
        case 10: return 11025;
        case 11: return 8000;
        case 12: return 7350;
        default: return 0;
    }
}

@interface TVUIRLAudioConfig ()
@property (nonatomic, readwrite) TVUIRLAacObjectType objectType;
@property (nonatomic, readwrite) Float64 sampleRate;
@property (nonatomic, readwrite) uint8_t channelCount;
@end

@implementation TVUIRLAudioConfig

- (nullable instancetype)initWithData:(NSData *)data {
    if (data.length < 2) return nil;
    if (self = [super init]) {
        const uint8_t *bytes = data.bytes;
        uint8_t typeRaw = bytes[0] >> 3;
        uint8_t freq = (uint8_t)(((bytes[0] & 0x07) << 1) | (bytes[1] >> 7));
        uint8_t channel = (uint8_t)((bytes[1] & 0x78) >> 3);
        if (typeRaw < 1 || typeRaw > 10) return nil;
        if (freq > 12) return nil;
        if (channel > 7) return nil;
        _objectType = (TVUIRLAacObjectType)typeRaw;
        _sampleRate = sampleRateFromIndex(freq);
        _channelCount = channel;
    }
    return self;
}

- (AudioStreamBasicDescription)audioStreamBasicDescription {
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = self.sampleRate;
    asbd.mFormatID = kAudioFormatMPEG4AAC;
    asbd.mFormatFlags = (UInt32)self.objectType;
    asbd.mBytesPerPacket = 0;
    asbd.mFramesPerPacket = 1024;
    asbd.mBytesPerFrame = 0;
    asbd.mChannelsPerFrame = (UInt32)self.channelCount;
    asbd.mBitsPerChannel = 0;
    asbd.mReserved = 0;
    return asbd;
}

- (nullable AVAudioFormat *)avAudioFormat {
    AudioStreamBasicDescription asbd = [self audioStreamBasicDescription];
    return [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
}

@end
