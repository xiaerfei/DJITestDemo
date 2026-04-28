//
//  TVUIRLMediaPacket.m
//  DJIStreamDemo
//

#import "TVUIRLMediaPacket.h"
#import "TVUIRLDataWriter.h"

static const uint32_t kMaxTimestamp = 0xFFFFFF;

static NSInteger basicHeaderSizeForId(uint16_t chunkStreamId) {
    if (chunkStreamId <= 63) return 1;
    if (chunkStreamId <= 319) return 2;
    return 3;
}

static NSInteger messageHeaderSizeForType(TVUIRLPacketType type) {
    switch (type) {
        case TVUIRLPacketTypeZero:  return 11;
        case TVUIRLPacketTypeOne:   return 7;
        case TVUIRLPacketTypeTwo:   return 3;
        case TVUIRLPacketTypeThree: return 0;
    }
}

static NSData *basicHeaderData(TVUIRLPacketType type, uint16_t chunkStreamId) {
    uint8_t fmt = (uint8_t)type;
    if (chunkStreamId <= 63) {
        uint8_t b = (uint8_t)((fmt << 6) | (uint8_t)chunkStreamId);
        return [NSData dataWithBytes:&b length:1];
    }
    if (chunkStreamId <= 319) {
        uint8_t b[2] = { (uint8_t)((fmt << 6) | 0x00), (uint8_t)(chunkStreamId - 64) };
        return [NSData dataWithBytes:b length:2];
    }
    uint16_t v = (uint16_t)(chunkStreamId - 64);
    uint8_t b[3] = {
        (uint8_t)((fmt << 6) | 0x01),
        (uint8_t)((v >> 8) & 0xFF),
        (uint8_t)(v & 0xFF),
    };
    return [NSData dataWithBytes:b length:3];
}

@interface TVUIRLMediaPacket ()
@property (nonatomic, readwrite) TVUIRLPacketType type;
@property (nonatomic, readwrite) uint16_t chunkStreamId;
@property (nonatomic, strong, readwrite) TVUIRLProtocolMessage *message;
@end

@implementation TVUIRLMediaPacket

- (instancetype)initWithType:(TVUIRLPacketType)type
               chunkStreamId:(uint16_t)chunkStreamId
                     message:(TVUIRLProtocolMessage *)message {
    if (self = [super init]) {
        _type = type;
        _chunkStreamId = chunkStreamId;
        _message = message;
    }
    return self;
}

- (NSData *)encodeChunk {
    TVUIRLProtocolMessage *message = self.message;
    NSData *body = message.encoded;
    TVUIRLDataWriter *writer = [[TVUIRLDataWriter alloc] init];
    [writer writeBytes:basicHeaderData(self.type, self.chunkStreamId)];
    if (message.timestamp > kMaxTimestamp) {
        [writer writeUInt24:kMaxTimestamp];
    } else {
        [writer writeUInt24:message.timestamp];
    }
    [writer writeUInt24:(uint32_t)body.length];
    [writer writeUInt8:(uint8_t)message.type];
    if (self.type == TVUIRLPacketTypeZero) {
        [writer writeUInt32Le:message.streamId];
    }
    if (message.timestamp > kMaxTimestamp) {
        [writer writeUInt32:message.timestamp];
    }
    NSMutableData *out = [NSMutableData dataWithData:writer.data];
    [out appendData:body];
    return out;
}

- (NSArray<NSData *> *)splitWithMaximumSize:(NSInteger)maximumSize {
    NSData *encoded = [self encodeChunk];
    self.message.length = (NSInteger)encoded.length;
    NSInteger bodyLength = (NSInteger)self.message.encoded.length;
    if (maximumSize >= bodyLength) {
        return @[encoded];
    }
    NSInteger headerSize = basicHeaderSizeForId(self.chunkStreamId) + messageHeaderSizeForType(self.type);
    NSInteger startIndex = maximumSize + headerSize;
    if (startIndex > (NSInteger)encoded.length) startIndex = (NSInteger)encoded.length;
    NSData *type3Header = basicHeaderData(TVUIRLPacketTypeThree, self.chunkStreamId);
    NSMutableArray<NSData *> *chunks = [NSMutableArray array];
    [chunks addObject:[encoded subdataWithRange:NSMakeRange(0, startIndex)]];
    for (NSInteger index = startIndex; index < (NSInteger)encoded.length; index += maximumSize) {
        NSInteger endIndex = ((index + maximumSize) < (NSInteger)encoded.length)
            ? (index + maximumSize)
            : (NSInteger)encoded.length;
        NSMutableData *combined = [NSMutableData dataWithData:type3Header];
        [combined appendData:[encoded subdataWithRange:NSMakeRange(index, endIndex - index)]];
        [chunks addObject:combined];
    }
    return chunks;
}

@end
