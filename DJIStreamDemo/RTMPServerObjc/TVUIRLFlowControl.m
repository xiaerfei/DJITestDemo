//
//  TVUIRLFlowControl.m
//  DJIStreamDemo
//

#import "TVUIRLFlowControl.h"

@implementation TVUIRLFlowControl

- (instancetype)init {
    return [super initWithType:TVUIRLMessageTypeChunkSize];
}

- (instancetype)initWithSize:(uint32_t)size {
    if (self = [super initWithType:TVUIRLMessageTypeChunkSize]) {
        _size = size;
    }
    return self;
}

- (NSData *)buildEncoded {
    uint8_t b[4] = {
        (uint8_t)((self.size >> 24) & 0xFF),
        (uint8_t)((self.size >> 16) & 0xFF),
        (uint8_t)((self.size >> 8) & 0xFF),
        (uint8_t)(self.size & 0xFF),
    };
    return [NSData dataWithBytes:b length:4];
}

- (void)parseEncoded:(NSData *)data {
    if (data.length < 4) return;
    uint8_t b[4];
    [data getBytes:b length:4];
    self.size = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                ((uint32_t)b[2] << 8)  | (uint32_t)b[3];
}

@end
