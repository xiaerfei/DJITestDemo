//
//  TVUIRLDataWriter.m
//  DJIStreamDemo
//

#import "TVUIRLDataWriter.h"

@interface TVUIRLDataWriter ()
@property (nonatomic, strong) NSMutableData *buffer;
@end

@implementation TVUIRLDataWriter

- (instancetype)init {
    if (self = [super init]) {
        _buffer = [NSMutableData data];
    }
    return self;
}

- (NSData *)data { return [self.buffer copy]; }
- (NSInteger)length { return (NSInteger)self.buffer.length; }

- (void)writeUInt8:(uint8_t)value {
    [self.buffer appendBytes:&value length:1];
}

- (void)writeUInt16:(uint16_t)value {
    uint8_t b[2] = { (uint8_t)((value >> 8) & 0xFF), (uint8_t)(value & 0xFF) };
    [self.buffer appendBytes:b length:2];
}

- (void)writeUInt16Le:(uint16_t)value {
    uint8_t b[2] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF) };
    [self.buffer appendBytes:b length:2];
}

- (void)writeUInt24:(uint32_t)value {
    uint8_t b[3] = {
        (uint8_t)((value >> 16) & 0xFF),
        (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)(value & 0xFF)
    };
    [self.buffer appendBytes:b length:3];
}

- (void)writeUInt24Le:(uint32_t)value {
    uint8_t b[3] = {
        (uint8_t)(value & 0xFF),
        (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF)
    };
    [self.buffer appendBytes:b length:3];
}

- (void)writeUInt32:(uint32_t)value {
    uint8_t b[4] = {
        (uint8_t)((value >> 24) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF),
        (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)(value & 0xFF)
    };
    [self.buffer appendBytes:b length:4];
}

- (void)writeUInt32Le:(uint32_t)value {
    uint8_t b[4] = {
        (uint8_t)(value & 0xFF),
        (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF),
        (uint8_t)((value >> 24) & 0xFF)
    };
    [self.buffer appendBytes:b length:4];
}

- (void)writeInt32Be:(int32_t)value {
    [self writeUInt32:(uint32_t)value];
}

- (void)writeDouble:(double)value {
    uint64_t v;
    memcpy(&v, &value, 8);
    uint8_t b[8] = {
        (uint8_t)((v >> 56) & 0xFF),
        (uint8_t)((v >> 48) & 0xFF),
        (uint8_t)((v >> 40) & 0xFF),
        (uint8_t)((v >> 32) & 0xFF),
        (uint8_t)((v >> 24) & 0xFF),
        (uint8_t)((v >> 16) & 0xFF),
        (uint8_t)((v >> 8) & 0xFF),
        (uint8_t)(v & 0xFF)
    };
    [self.buffer appendBytes:b length:8];
}

- (void)writeUtf8Bytes:(NSString *)value {
    NSData *encoded = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (encoded) [self.buffer appendData:encoded];
}

- (void)writeBytes:(NSData *)data {
    if (data.length > 0) [self.buffer appendData:data];
}

@end
