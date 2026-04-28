//
//  TVUIRLAudioConfig.h
//  DJIStreamDemo
//
//  解析 AudioSpecificConfig（AAC 序列头），生成 AudioStreamBasicDescription / AVAudioFormat。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudioTypes.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, TVUIRLAacObjectType) {
    TVUIRLAacObjectTypeUnknown    = 0,
    TVUIRLAacObjectTypeAacMain    = 1,
    TVUIRLAacObjectTypeAacLc      = 2,
    TVUIRLAacObjectTypeAacSsr     = 3,
    TVUIRLAacObjectTypeAacLtp     = 4,
    TVUIRLAacObjectTypeAacSbr     = 5,
    TVUIRLAacObjectTypeAacScalable= 6,
    TVUIRLAacObjectTypeTwinVQ     = 7,
    TVUIRLAacObjectTypeCelp       = 8,
    TVUIRLAacObjectTypeHvxc       = 9,
    TVUIRLAacObjectTypeOpus       = 10,
};

@interface TVUIRLAudioConfig : NSObject

@property (nonatomic, readonly) TVUIRLAacObjectType objectType;
@property (nonatomic, readonly) Float64 sampleRate;
@property (nonatomic, readonly) uint8_t channelCount;

/// 从 AudioSpecificConfig（FLV Audio Tag payload 跳过控制字节后的数据）创建配置。
/// 参数无效时返回 nil。
- (nullable instancetype)initWithData:(NSData *)data;

- (AudioStreamBasicDescription)audioStreamBasicDescription;
- (nullable AVAudioFormat *)avAudioFormat;

@end

NS_ASSUME_NONNULL_END
