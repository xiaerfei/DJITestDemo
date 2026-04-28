//
//  TVUIRLBandwidthConfig.h
//  DJIStreamDemo
//
//  RTMP Set Peer Bandwidth (type 0x06)：4 字节大端 size + 1 字节 limit type。
//

#import "TVUIRLProtocolMessage.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, TVUIRLBandwidthLimit) {
    TVUIRLBandwidthLimitHard    = 0x00,
    TVUIRLBandwidthLimitSoft    = 0x01,
    TVUIRLBandwidthLimitDynamic = 0x02,
    TVUIRLBandwidthLimitUnknown = 0xFF,
};

@interface TVUIRLBandwidthConfig : TVUIRLProtocolMessage

@property (nonatomic, assign) uint32_t size;
@property (nonatomic, assign) TVUIRLBandwidthLimit limit;

- (instancetype)init;
- (instancetype)initWithSize:(uint32_t)size limit:(TVUIRLBandwidthLimit)limit;

@end

NS_ASSUME_NONNULL_END
