//
//  TVUIRLHardwareDecoder.h
//  DJIStreamDemo
//
//  H.264/H.265 视频硬解码（VTDecompressionSession）。
//  调用方先用 setupWithFormatDescription: 建立会话，再持续 decodeSampleBuffer:。
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@class TVUIRLHardwareDecoder;

@protocol TVUIRLHardwareDecoderDelegate <NSObject>
- (void)hardwareDecoder:(TVUIRLHardwareDecoder *)decoder didDecodeSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@optional
- (void)hardwareDecoder:(TVUIRLHardwareDecoder *)decoder didDecodeImageBuffer:(CVImageBufferRef)imageBuffer;
@end

@interface TVUIRLHardwareDecoder : NSObject

@property (nonatomic, weak, nullable) id<TVUIRLHardwareDecoderDelegate> delegate;

- (instancetype)initWithQueue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startWithFormatDescription:(CMVideoFormatDescriptionRef)formatDescription;
- (void)stop;
- (void)decodeSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END
