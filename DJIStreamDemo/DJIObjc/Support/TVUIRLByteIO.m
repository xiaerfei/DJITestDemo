//
//  TVUIRLByteIO.m
//  DJIStreamDemo
//

#import "TVUIRLByteIO.h"

NSErrorDomain const TVUIRLByteIOErrorDomain = @"TVUIRLByteIOErrorDomain";

/// 构造一个 OutOfBounds 错误的便捷函数
static NSError *MakeOutOfBoundsError(NSString *message) {
    return [NSError errorWithDomain:TVUIRLByteIOErrorDomain
                               code:TVUIRLByteIOErrorOutOfBounds
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Out of bounds"}];
}

#pragma mark - TVUIRLByteReader

@implementation TVUIRLByteReader {
    NSData *_data;          // 不可变数据源（拷贝一份避免被外部修改）
    NSUInteger _position;   // 光标位置：下一个待读字节的下标
}

- (instancetype)initWithData:(NSData *)data {
    self = [super init];
    if (self) {
        _data = [data copy];
        _position = 0;
    }
    return self;
}

- (NSUInteger)bytesAvailable {
    return _data.length - _position;
}

- (NSUInteger)position {
    return _position;
}

- (BOOL)readUInt8:(uint8_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 1) {
        if (error) *error = MakeOutOfBoundsError(@"Need 1 byte");
        return NO;
    }
    const uint8_t *bytes = (const uint8_t *)_data.bytes;
    *outValue = bytes[_position];
    _position += 1;
    return YES;
}

- (BOOL)readUInt16Le:(uint16_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 2) {
        if (error) *error = MakeOutOfBoundsError(@"Need 2 bytes");
        return NO;
    }
    // 小端：低字节在前，高字节在后
    const uint8_t *bytes = (const uint8_t *)_data.bytes;
    uint16_t value = (uint16_t)bytes[_position] | ((uint16_t)bytes[_position + 1] << 8);
    *outValue = value;
    _position += 2;
    return YES;
}

- (BOOL)readUInt24Le:(uint32_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 3) {
        if (error) *error = MakeOutOfBoundsError(@"Need 3 bytes");
        return NO;
    }
    // 3 字节小端组装，bit23 用 0 填充
    const uint8_t *bytes = (const uint8_t *)_data.bytes;
    uint32_t value = (uint32_t)bytes[_position]
                   | ((uint32_t)bytes[_position + 1] << 8)
                   | ((uint32_t)bytes[_position + 2] << 16);
    *outValue = value;
    _position += 3;
    return YES;
}

- (nullable NSData *)readBytes:(NSUInteger)count error:(NSError **)error {
    if (self.bytesAvailable < count) {
        if (error) *error = MakeOutOfBoundsError([NSString stringWithFormat:@"Need %lu bytes", (unsigned long)count]);
        return nil;
    }
    NSData *slice = [_data subdataWithRange:NSMakeRange(_position, count)];
    _position += count;
    return slice;
}

@end

#pragma mark - TVUIRLByteWriter

@implementation TVUIRLByteWriter {
    NSMutableData *_buffer;  // 可变缓冲区，每次写入都追加到尾部
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = [NSMutableData data];
    }
    return self;
}

- (NSData *)data {
    // 返回一份不可变拷贝，调用方拿到后即使修改也不会影响内部状态
    return [_buffer copy];
}

- (void)writeUInt8:(uint8_t)value {
    [_buffer appendBytes:&value length:1];
}

- (void)writeUInt16Le:(uint16_t)value {
    // 小端：低字节先写入
    uint8_t bytes[2] = {
        (uint8_t)(value & 0xFF),
        (uint8_t)((value >> 8) & 0xFF)
    };
    [_buffer appendBytes:bytes length:2];
}

- (void)writeUInt24Le:(uint32_t)value {
    // 3 字节小端，最高位字节舍弃
    uint8_t bytes[3] = {
        (uint8_t)(value & 0xFF),
        (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF)
    };
    [_buffer appendBytes:bytes length:3];
}

- (void)writeBytes:(NSData *)data {
    [_buffer appendData:data];
}

@end
