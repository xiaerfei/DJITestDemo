//
//  TVUIRLAmfEncoder.m
//  DJIStreamDemo
//

#import "TVUIRLAmfEncoder.h"

typedef NS_ENUM(uint8_t, TVUIRLAmf0Marker) {
    TVUIRLAmf0MarkerNumber       = 0x00,
    TVUIRLAmf0MarkerBool         = 0x01,
    TVUIRLAmf0MarkerString       = 0x02,
    TVUIRLAmf0MarkerObject       = 0x03,
    TVUIRLAmf0MarkerNull         = 0x05,
    TVUIRLAmf0MarkerUndefined    = 0x06,
    TVUIRLAmf0MarkerReference    = 0x07,
    TVUIRLAmf0MarkerEcmaArray    = 0x08,
    TVUIRLAmf0MarkerObjectEnd    = 0x09,
    TVUIRLAmf0MarkerStrictArray  = 0x0A,
    TVUIRLAmf0MarkerDate         = 0x0B,
    TVUIRLAmf0MarkerLongString   = 0x0C,
    TVUIRLAmf0MarkerUnsupported  = 0x0D,
    TVUIRLAmf0MarkerXmlDocument  = 0x0F,
    TVUIRLAmf0MarkerTypedObject  = 0x10,
    TVUIRLAmf0MarkerAvmplush     = 0x11,
};

@implementation TVUIRLAmfEncoder

- (void)writeMarker:(TVUIRLAmf0Marker)marker {
    [self writeUInt8:(uint8_t)marker];
}

- (void)encodeShortString:(NSString *)value {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    [self writeUInt16:(uint16_t)data.length];
    [self writeBytes:data];
}

- (void)encodeLongString:(NSData *)data {
    [self writeUInt32:(uint32_t)data.length];
    [self writeBytes:data];
}

- (void)encodeString:(NSString *)value {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    if ((uint32_t)data.length > (uint32_t)UINT16_MAX) {
        [self writeMarker:TVUIRLAmf0MarkerLongString];
        [self encodeLongString:data];
    } else {
        [self writeMarker:TVUIRLAmf0MarkerString];
        [self writeUInt16:(uint16_t)data.length];
        [self writeBytes:data];
    }
}

- (void)encodeNumber:(double)value {
    [self writeMarker:TVUIRLAmf0MarkerNumber];
    [self writeDouble:value];
}

- (void)encodeBool:(BOOL)value {
    uint8_t b[2] = { TVUIRLAmf0MarkerBool, value ? 0x01 : 0x00 };
    [self writeBytes:[NSData dataWithBytes:b length:2]];
}

- (void)encodeObject:(NSDictionary<NSString *, TVUIRLAmfValue *> *)value {
    [self writeMarker:TVUIRLAmf0MarkerObject];
    for (NSString *key in value) {
        [self encodeShortString:key];
        [self encodeValue:value[key]];
    }
    [self encodeShortString:@""];
    [self writeMarker:TVUIRLAmf0MarkerObjectEnd];
}

- (void)encodeDate:(NSDate *)value {
    [self writeMarker:TVUIRLAmf0MarkerDate];
    [self writeDouble:[value timeIntervalSince1970] * 1000.0];
    [self writeUInt16:0];
}

- (void)encodeValue:(TVUIRLAmfValue *)value {
    switch (value.type) {
        case TVUIRLAmfValueTypeNumber:
            [self encodeNumber:[value doubleValue]];
            break;
        case TVUIRLAmfValueTypeBoolean:
            [self encodeBool:[value boolValue]];
            break;
        case TVUIRLAmfValueTypeString:
            [self encodeString:[value stringValue] ?: @""];
            break;
        case TVUIRLAmfValueTypeObject:
            [self encodeObject:[value objectValue] ?: @{}];
            break;
        case TVUIRLAmfValueTypeNull:
            [self writeMarker:TVUIRLAmf0MarkerNull];
            break;
        case TVUIRLAmfValueTypeDate:
            [self encodeDate:[value dateValue] ?: [NSDate dateWithTimeIntervalSince1970:0]];
            break;
        case TVUIRLAmfValueTypeEcmaArray:
            [self writeMarker:TVUIRLAmf0MarkerEcmaArray];
            [self writeUInt32:0];
            for (NSString *key in [value objectValue]) {
                [self encodeShortString:key];
                [self encodeValue:[value objectValue][key]];
            }
            [self encodeShortString:@""];
            [self writeMarker:TVUIRLAmf0MarkerObjectEnd];
            break;
        case TVUIRLAmfValueTypeUndefined:
        default:
            [self writeMarker:TVUIRLAmf0MarkerUndefined];
            break;
    }
}

@end
