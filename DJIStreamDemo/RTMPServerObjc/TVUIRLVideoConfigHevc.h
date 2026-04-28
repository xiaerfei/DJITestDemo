//
//  TVUIRLVideoConfigHevc.h
//  DJIStreamDemo
//
//  解析 HEVCDecoderConfigurationRecord（含 VPS+SPS+PPS），创建 H.265 CMVideoFormatDescription。
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, TVUIRLHevcNalUnitType) {
    TVUIRLHevcNalUnitTypeVps   = 32,
    TVUIRLHevcNalUnitTypeSps   = 33,
    TVUIRLHevcNalUnitTypePps   = 34,
    TVUIRLHevcNalUnitTypeUnspec = 0xFF,
};

@interface TVUIRLVideoConfigHevc : NSObject

@property (nonatomic, copy, nullable, readonly) NSData *videoParameterSet;
@property (nonatomic, copy, nullable, readonly) NSData *sequenceParameterSet;
@property (nonatomic, copy, nullable, readonly) NSData *pictureParameterSet;

- (instancetype)initWithHvcC:(NSData *)hvcC NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (OSStatus)makeFormatDescription:(CMVideoFormatDescriptionRef _Nullable * _Nonnull)formatDescriptionOut;

@end

NS_ASSUME_NONNULL_END
