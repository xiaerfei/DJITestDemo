//
//  TVUIRLBandwidthConfig.m
//  DJIStreamDemo
//

#import "TVUIRLBandwidthConfig.h"

@implementation TVUIRLBandwidthConfig

- (instancetype)init {
    if (self = [super initWithType:TVUIRLMessageTypeBandwidth]) {
        _limit = TVUIRLBandwidthLimitHard;
    }
    return self;
}

- (instancetype)initWithSize:(uint32_t)size limit:(TVUIRLBandwidthLimit)limit {
    if (self = [super initWithType:TVUIRLMessageTypeBandwidth]) {
        _size = size;
        _limit = limit;
    }
    return self;
}

- (NSData *)buildEncoded {
    uint8_t b[5] = {
        (uint8_t)((self.size >> 24) & 0xFF),
        (uint8_t)((self.size >> 16) & 0xFF),
        (uint8_t)((self.size >> 8) & 0xFF),
        (uint8_t)(self.size & 0xFF),
        (uint8_t)self.limit,
    };
    return [NSData dataWithBytes:b length:5];
}

- (void)parseEncoded:(NSData *)data {
    if (data.length < 5) return;
    uint8_t b[5];
    [data getBytes:b length:5];
    self.size = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                ((uint32_t)b[2] << 8)  | (uint32_t)b[3];
    switch (b[4]) {
        case TVUIRLBandwidthLimitHard:
        case TVUIRLBandwidthLimitSoft:
        case TVUIRLBandwidthLimitDynamic:
            self.limit = (TVUIRLBandwidthLimit)b[4];
            break;
        default:
            self.limit = TVUIRLBandwidthLimitUnknown;
            break;
    }
}

@end
