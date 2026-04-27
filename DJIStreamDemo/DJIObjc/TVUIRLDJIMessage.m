//
//  TVUIRLDJIMessage.m
//  DJIStreamDemo
//

#import "TVUIRLDJIMessage.h"
#import "TVUIRLByteIO.h"
#import "TVUIRLDJICrc.h"

NSErrorDomain const TVUIRLDJIMessageErrorDomain = @"TVUIRLDJIMessageErrorDomain";

#pragma mark - 字段打包工具

NSData *TVUIRLDJIPackString(NSString *value) {
    // 1 字节长度前缀（截断到 0~255）+ UTF-8 字节
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSMutableData *out = [NSMutableData dataWithCapacity:utf8.length + 1];
    uint8_t lenByte = (uint8_t)(utf8.length & 0xFF);
    [out appendBytes:&lenByte length:1];
    [out appendData:utf8];
    return out;
}

NSData *TVUIRLDJIPackUrl(NSString *url) {
    // 长度（1 字节）+ 保留字节 0x00 + UTF-8 字节
    // 这个 0x00 的具体含义未公开，但是协议要求必须有，缺了相机不会推流。
    NSData *utf8 = [url dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSMutableData *out = [NSMutableData dataWithCapacity:utf8.length + 2];
    uint8_t lenByte = (uint8_t)(utf8.length & 0xFF);
    uint8_t zero = 0;
    [out appendBytes:&lenByte length:1];
    [out appendBytes:&zero length:1];
    [out appendData:utf8];
    return out;
}

NSString *TVUIRLDJIHexString(NSData *data) {
    if (data.length == 0) return @"";
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        [s appendFormat:@"%02hhx", bytes[i]];
    }
    return s;
}

/// 构造帧错误的便捷函数
static NSError *MakeMessageError(TVUIRLDJIMessageError code, NSString *message) {
    return [NSError errorWithDomain:TVUIRLDJIMessageErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

#pragma mark - TVUIRLDJIMessage

@implementation TVUIRLDJIMessage

- (instancetype)initWithTarget:(uint16_t)target
                     messageId:(uint16_t)messageId
                          type:(uint32_t)type
                       payload:(NSData *)payload {
    self = [super init];
    if (self) {
        _target = target;
        _messageId = messageId;
        _type = type;
        _payload = [payload copy] ?: [NSData data];
    }
    return self;
}

- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    TVUIRLByteReader *reader = [[TVUIRLByteReader alloc] initWithData:data];
    NSError *innerError = nil;

    // ── 1) 起始字节 0x55 ──────────────────────────────────────────
    uint8_t firstByte = 0;
    if (![reader readUInt8:&firstByte error:&innerError]) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorTruncated, @"Truncated header");
        return nil;
    }
    if (firstByte != 0x55) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorBadFirstByte, @"Bad first byte");
        return nil;
    }

    // ── 2) 帧长度字段必须等于实际数据长度 ─────────────────────────
    uint8_t length = 0;
    if (![reader readUInt8:&length error:&innerError]) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorTruncated, @"Missing length");
        return nil;
    }
    if (data.length != (NSUInteger)length) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorBadLength, @"Bad length");
        return nil;
    }

    // ── 3) 版本字段固定为 0x04 ────────────────────────────────────
    uint8_t version = 0;
    if (![reader readUInt8:&version error:&innerError]) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorTruncated, @"Missing version");
        return nil;
    }
    if (version != 0x04) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorBadVersion, @"Bad version");
        return nil;
    }

    // ── 4) 头部 CRC8 校验：用前 3 个字节算出来再和读到的值比较 ────
    uint8_t headerCrc = 0;
    if (![reader readUInt8:&headerCrc error:&innerError]) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorTruncated, @"Missing header CRC");
        return nil;
    }
    NSData *headerForCrc = [data subdataWithRange:NSMakeRange(0, 3)];
    uint8_t calculatedHeaderCrc = [TVUIRLDJICrc crc8:headerForCrc];
    if (headerCrc != calculatedHeaderCrc) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorHeaderCrcMismatch,
                                              [NSString stringWithFormat:@"Header CRC %u != %u",
                                               calculatedHeaderCrc, headerCrc]);
        return nil;
    }

    // ── 5) target / messageId / type 三个固定字段（小端） ─────────
    uint16_t target = 0;
    uint16_t mid = 0;
    uint32_t type = 0;
    if (![reader readUInt16Le:&target error:&innerError] ||
        ![reader readUInt16Le:&mid error:&innerError] ||
        ![reader readUInt24Le:&type error:&innerError]) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorTruncated, @"Missing fields");
        return nil;
    }

    // ── 6) 载荷 = 剩余字节去掉末尾 2 字节（CRC16） ────────────────
    NSUInteger remaining = reader.bytesAvailable;
    if (remaining < 2) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorTruncated, @"Missing CRC trailer");
        return nil;
    }
    NSData *payload = [reader readBytes:remaining - 2 error:&innerError];
    if (!payload) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorTruncated, @"Missing payload");
        return nil;
    }

    // ── 7) 帧体 CRC16 校验 ────────────────────────────────────────
    uint16_t crc = 0;
    if (![reader readUInt16Le:&crc error:&innerError]) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorTruncated, @"Missing CRC");
        return nil;
    }
    // 校验范围：从帧首到 payload 末尾（即除尾部 2 字节 CRC16 之外的全部）
    NSData *body = [data subdataWithRange:NSMakeRange(0, data.length - 2)];
    uint16_t calculatedCrc = [TVUIRLDJICrc crc16:body];
    if (crc != calculatedCrc) {
        if (error) *error = MakeMessageError(TVUIRLDJIMessageErrorBodyCrcMismatch,
                                              [NSString stringWithFormat:@"Body CRC %u != %u",
                                               calculatedCrc, crc]);
        return nil;
    }

    _target = target;
    _messageId = mid;
    _type = type;
    _payload = payload;
    return self;
}

- (NSData *)encode {
    TVUIRLByteWriter *writer = [[TVUIRLByteWriter alloc] init];

    // ① 起始字节
    [writer writeUInt8:0x55];
    // ② 总长度 = 13 字节固定字段 (start + length + version + crc8 + target2 + id2 + type3 + crc16=2) + payload 长度
    [writer writeUInt8:(uint8_t)((13 + _payload.length) & 0xFF)];
    // ③ 版本
    [writer writeUInt8:0x04];
    // ④ 头部 CRC8（基于已写入的前 3 字节）
    [writer writeUInt8:[TVUIRLDJICrc crc8:writer.data]];

    // ⑤~⑦ target / id / type（都是小端）
    [writer writeUInt16Le:_target];
    [writer writeUInt16Le:_messageId];
    [writer writeUInt24Le:_type];

    // ⑧ 载荷
    [writer writeBytes:_payload];

    // ⑨ 帧体 CRC16（基于到此为止的全部字节）
    uint16_t crc = [TVUIRLDJICrc crc16:writer.data];
    [writer writeUInt16Le:crc];

    return writer.data;
}

- (NSString *)format {
    return [NSString stringWithFormat:@"target: %u, id: %u, type: %u %@",
            _target, _messageId, _type, TVUIRLDJIHexString(_payload)];
}

@end
