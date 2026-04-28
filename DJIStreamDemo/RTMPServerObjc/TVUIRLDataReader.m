//
//  TVUIRLDataReader.m
//  DJIStreamDemo
//

#import "TVUIRLDataReader.h"

NSErrorDomain const TVUIRLDataReaderErrorDomain = @"TVUIRLDataReaderErrorDomain";

@interface TVUIRLDataReader ()
@property (nonatomic, copy, readwrite) NSData *data;
@end

@implementation TVUIRLDataReader

- (instancetype)initWithData:(NSData *)data {
    if (self = [super init]) {
        _data = [data copy];
        _position = 0;
    }
    return self;
}

- (NSInteger)bytesAvailable {
    return (NSInteger)self.data.length - self.position;
}

static BOOL setEOFError(NSError **error) {
    if (error) {
        *error = [NSError errorWithDomain:TVUIRLDataReaderErrorDomain
                                     code:TVUIRLDataReaderErrorEOF
                                 userInfo:@{NSLocalizedDescriptionKey: @"EOF"}];
    }
    return NO;
}

- (BOOL)readUInt8:(uint8_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 1) return setEOFError(error);
    [self.data getBytes:outValue range:NSMakeRange(self.position, 1)];
    self.position += 1;
    return YES;
}

- (BOOL)readUInt16:(uint16_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 2) return setEOFError(error);
    uint8_t bytes[2];
    [self.data getBytes:bytes range:NSMakeRange(self.position, 2)];
    *outValue = ((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1];
    self.position += 2;
    return YES;
}

- (BOOL)readUInt16Le:(uint16_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 2) return setEOFError(error);
    uint8_t bytes[2];
    [self.data getBytes:bytes range:NSMakeRange(self.position, 2)];
    *outValue = (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
    self.position += 2;
    return YES;
}

- (BOOL)readUInt24:(uint32_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 3) return setEOFError(error);
    uint8_t bytes[3];
    [self.data getBytes:bytes range:NSMakeRange(self.position, 3)];
    *outValue = ((uint32_t)bytes[0] << 16) | ((uint32_t)bytes[1] << 8) | (uint32_t)bytes[2];
    self.position += 3;
    return YES;
}

- (BOOL)readUInt24Le:(uint32_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 3) return setEOFError(error);
    uint8_t bytes[3];
    [self.data getBytes:bytes range:NSMakeRange(self.position, 3)];
    *outValue = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16);
    self.position += 3;
    return YES;
}

- (BOOL)readUInt32:(uint32_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 4) return setEOFError(error);
    uint8_t bytes[4];
    [self.data getBytes:bytes range:NSMakeRange(self.position, 4)];
    *outValue = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
                ((uint32_t)bytes[2] << 8)  | (uint32_t)bytes[3];
    self.position += 4;
    return YES;
}

- (BOOL)readUInt32Le:(uint32_t *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 4) return setEOFError(error);
    uint8_t bytes[4];
    [self.data getBytes:bytes range:NSMakeRange(self.position, 4)];
    *outValue = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
                ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
    self.position += 4;
    return YES;
}

- (BOOL)readDouble:(double *)outValue error:(NSError **)error {
    if (self.bytesAvailable < 8) return setEOFError(error);
    uint8_t bytes[8];
    [self.data getBytes:bytes range:NSMakeRange(self.position, 8)];
    uint64_t v = ((uint64_t)bytes[0] << 56) | ((uint64_t)bytes[1] << 48) |
                 ((uint64_t)bytes[2] << 40) | ((uint64_t)bytes[3] << 32) |
                 ((uint64_t)bytes[4] << 24) | ((uint64_t)bytes[5] << 16) |
                 ((uint64_t)bytes[6] << 8)  | (uint64_t)bytes[7];
    double d;
    memcpy(&d, &v, 8);
    *outValue = d;
    self.position += 8;
    return YES;
}

- (NSString *)readUtf8BytesOfLength:(NSInteger)length error:(NSError **)error {
    if (self.bytesAvailable < length) {
        setEOFError(error);
        return nil;
    }
    NSData *slice = [self.data subdataWithRange:NSMakeRange(self.position, length)];
    NSString *result = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (!result) {
        if (error) {
            *error = [NSError errorWithDomain:TVUIRLDataReaderErrorDomain
                                         code:TVUIRLDataReaderErrorUTF8
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid UTF-8"}];
        }
        return nil;
    }
    self.position += length;
    return result;
}

- (NSData *)readBytesOfLength:(NSInteger)length error:(NSError **)error {
    if (length < 0 || self.bytesAvailable < length) {
        setEOFError(error);
        return nil;
    }
    NSData *slice = [self.data subdataWithRange:NSMakeRange(self.position, length)];
    self.position += length;
    return slice;
}

- (BOOL)skipBytes:(NSInteger)length error:(NSError **)error {
    if (length < 0 || self.bytesAvailable < length) return setEOFError(error);
    self.position += length;
    return YES;
}

@end
