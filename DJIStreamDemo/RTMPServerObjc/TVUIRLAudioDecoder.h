//
//  TVUIRLAudioDecoder.h
//  DJIStreamDemo
//
//  AAC → PCM 解码（AVAudioConverter）。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import "TVUIRLStreamConnection.h"
NS_ASSUME_NONNULL_BEGIN

@class TVUIRLAudioConfig;
@class TVUIRLAudioDecoder;

@protocol TVUIRLAudioDecoderDelegate <NSObject>
- (void)audioDecoder:(TVUIRLAudioDecoder *)decoder didDecodeSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface TVUIRLAudioDecoder : NSObject

@property (nonatomic, weak, nullable) id<TVUIRLAudioDecoderDelegate> delegate;
/// 解码出口 PTS 重锚委托。设置后产出的 sampleBuffer 的 PTS 会被重写为 host time 域。
@property (nonatomic, weak, nullable) id<TVUIRLDecodedPtsAnchor> ptsAnchor;
@property (nonatomic, readonly) BOOL isReady;

- (instancetype)init;

/// 用 AAC 序列头创建解码器。
- (BOOL)configureWithAudioConfig:(TVUIRLAudioConfig *)config;

/// 输入 AAC raw 帧，输出 PCM 通过 delegate。
- (void)decodeAacFrame:(NSData *)aacFrame
  presentationTimeStamp:(CMTime)pts;

@end

NS_ASSUME_NONNULL_END
