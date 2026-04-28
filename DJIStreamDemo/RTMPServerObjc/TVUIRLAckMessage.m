//
//  TVUIRLAckMessage.m
//  DJIStreamDemo
//

#import "TVUIRLAckMessage.h"

@implementation TVUIRLAckMessage

- (instancetype)init {
    return [super initWithType:TVUIRLMessageTypeAck];
}

- (NSData *)buildEncoded {
    uint8_t b[4] = {
        (uint8_t)((self.sequence >> 24) & 0xFF),
        (uint8_t)((self.sequence >> 16) & 0xFF),
        (uint8_t)((self.sequence >> 8) & 0xFF),
        (uint8_t)(self.sequence & 0xFF),
    };
    return [NSData dataWithBytes:b length:4];
}

- (void)parseEncoded:(NSData *)data {
    if (data.length < 4) return;
    uint8_t b[4];
    [data getBytes:b length:4];
    self.sequence = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                    ((uint32_t)b[2] << 8)  | (uint32_t)b[3];
}

@end
