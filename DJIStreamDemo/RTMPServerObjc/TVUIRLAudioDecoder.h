//
//  TVUIRLAudioDecoder.h
//  DJIStreamDemo
//
//  AAC → PCM 解码（AVAudioConverter）。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@class TVUIRLAudioConfig;
@class TVUIRLAudioDecoder;

@protocol TVUIRLAudioDecoderDelegate <NSObject>
- (void)audioDecoder:(TVUIRLAudioDecoder *)decoder didDecodeSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface TVUIRLAudioDecoder : NSObject

@property (nonatomic, weak, nullable) id<TVUIRLAudioDecoderDelegate> delegate;
@property (nonatomic, readonly) BOOL isReady;

- (instancetype)init;

/// 用 AAC 序列头创建解码器。
- (BOOL)configureWithAudioConfig:(TVUIRLAudioConfig *)config;

/// 输入 AAC raw 帧，输出 PCM 通过 delegate。
- (void)decodeAacFrame:(NSData *)aacFrame
  presentationTimeStamp:(CMTime)pts;

@end

NS_ASSUME_NONNULL_END
