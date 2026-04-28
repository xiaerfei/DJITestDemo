//
//  TVUIRLVideoConfigAvc.h
//  DJIStreamDemo
//
//  解析 AVCDecoderConfigurationRecord（含 SPS+PPS），创建 H.264 CMVideoFormatDescription。
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLVideoConfigAvc : NSObject

@property (nonatomic, copy, nullable, readonly) NSData *sequenceParameterSet;
@property (nonatomic, copy, nullable, readonly) NSData *pictureParameterSet;

- (instancetype)initWithAvcC:(NSData *)avcC NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (OSStatus)makeFormatDescription:(CMVideoFormatDescriptionRef _Nullable * _Nonnull)formatDescriptionOut;

@end

NS_ASSUME_NONNULL_END
