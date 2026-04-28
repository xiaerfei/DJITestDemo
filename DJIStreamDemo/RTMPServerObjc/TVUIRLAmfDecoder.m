//
//  TVUIRLAmfDecoder.m
//  DJIStreamDemo
//

#import "TVUIRLAmfDecoder.h"

NSErrorDomain const TVUIRLAmfDecoderErrorDomain = @"TVUIRLAmfDecoderErrorDomain";

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

@implementation TVUIRLAmfDecoder

static NSError *amfError(TVUIRLAmfDecoderError code, NSString *desc) {
    return [NSError errorWithDomain:TVUIRLAmfDecoderErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: desc}];
}

- (BOOL)readMarker:(TVUIRLAmf0Marker *)outMarker error:(NSError **)error {
    uint8_t b = 0;
    if (![self readUInt8:&b error:error]) return NO;
    switch (b) {
        case TVUIRLAmf0MarkerNumber: case TVUIRLAmf0MarkerBool: case TVUIRLAmf0MarkerString:
        case TVUIRLAmf0MarkerObject: case TVUIRLAmf0MarkerNull: case TVUIRLAmf0MarkerUndefined:
        case TVUIRLAmf0MarkerReference: case TVUIRLAmf0MarkerEcmaArray:
        case TVUIRLAmf0MarkerObjectEnd: case TVUIRLAmf0MarkerStrictArray:
        case TVUIRLAmf0MarkerDate: case TVUIRLAmf0MarkerLongString:
        case TVUIRLAmf0MarkerUnsupported: case TVUIRLAmf0MarkerXmlDocument:
        case TVUIRLAmf0MarkerTypedObject: case TVUIRLAmf0MarkerAvmplush:
            *outMarker = (TVUIRLAmf0Marker)b;
            return YES;
        default:
            if (error) *error = amfError(TVUIRLAmfDecoderErrorNotAmf0, @"Unknown AMF0 marker");
            return NO;
    }
}

- (nullable NSString *)decodeShortStringValue:(NSError **)error {
    uint16_t length = 0;
    if (![self readUInt16:&length error:error]) return nil;
    return [self readUtf8BytesOfLength:(NSInteger)length error:error];
}

- (nullable NSString *)decodeLongStringValue:(NSError **)error {
    uint32_t length = 0;
    if (![self readUInt32:&length error:error]) return nil;
    return [self readUtf8BytesOfLength:(NSInteger)length error:error];
}

- (BOOL)readNumberOfArrayElements:(uint32_t *)outCount error:(NSError **)error {
    uint32_t count = 0;
    if (![self readUInt32:&count error:error]) return NO;
    if (count >= 128) {
        if (error) *error = amfError(TVUIRLAmfDecoderErrorArrayTooBig, @"Array too big");
        return NO;
    }
    *outCount = count;
    return YES;
}

- (BOOL)parseObjectEnd:(NSError **)error {
    uint8_t b = 0;
    if (![self readUInt8:&b error:error]) return NO;
    if (b != TVUIRLAmf0MarkerObjectEnd) {
        if (error) *error = amfError(TVUIRLAmfDecoderErrorNotObjectEnd, @"Expected object end");
        return NO;
    }
    return YES;
}

- (nullable NSDictionary<NSString *, TVUIRLAmfValue *> *)decodeObjectValue:(NSError **)error {
    NSMutableDictionary<NSString *, TVUIRLAmfValue *> *object = [NSMutableDictionary dictionary];
    while (1) {
        NSString *key = [self decodeShortStringValue:error];
        if (key == nil) return nil;
        if (key.length == 0) break;
        TVUIRLAmfValue *value = [self decodeWithError:error];
        if (value == nil) return nil;
        object[key] = value;
    }
    if (![self parseObjectEnd:error]) return nil;
    return object;
}

- (nullable NSDictionary<NSString *, TVUIRLAmfValue *> *)decodeEcmaArrayValue:(NSError **)error {
    uint32_t numberOfElements = 0;
    if (![self readNumberOfArrayElements:&numberOfElements error:error]) return nil;
    return [self decodeObjectValue:error];
}

- (nullable NSArray<TVUIRLAmfValue *> *)decodeStrictArrayValue:(NSError **)error {
    uint32_t numberOfElements = 0;
    if (![self readNumberOfArrayElements:&numberOfElements error:error]) return nil;
    NSMutableArray<TVUIRLAmfValue *> *result = [NSMutableArray array];
    for (uint32_t i = 0; i < numberOfElements; i++) {
        TVUIRLAmfValue *v = [self decodeWithError:error];
        if (v == nil) return nil;
        [result addObject:v];
    }
    return result;
}

- (nullable NSDate *)decodeDateValue:(NSError **)error {
    double ms = 0;
    if (![self readDouble:&ms error:error]) return nil;
    uint16_t tz = 0;
    if (![self readUInt16:&tz error:error]) return nil;
    return [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
}

- (nullable TVUIRLAmfValue *)decodeWithError:(NSError **)error {
    TVUIRLAmf0Marker marker;
    if (![self readMarker:&marker error:error]) return nil;
    switch (marker) {
        case TVUIRLAmf0MarkerNumber: {
            double v = 0;
            if (![self readDouble:&v error:error]) return nil;
            return [TVUIRLAmfValue numberValue:v];
        }
        case TVUIRLAmf0MarkerBool: {
            uint8_t v = 0;
            if (![self readUInt8:&v error:error]) return nil;
            return [TVUIRLAmfValue boolValue:v == 0x01];
        }
        case TVUIRLAmf0MarkerString: {
            NSString *s = [self decodeShortStringValue:error];
            if (!s) return nil;
            return [TVUIRLAmfValue stringValue:s];
        }
        case TVUIRLAmf0MarkerObject: {
            NSDictionary *o = [self decodeObjectValue:error];
            if (!o) return nil;
            return [TVUIRLAmfValue objectValue:o];
        }
        case TVUIRLAmf0MarkerNull:
            return [TVUIRLAmfValue nullValue];
        case TVUIRLAmf0MarkerUndefined:
            return [TVUIRLAmfValue undefinedValue];
        case TVUIRLAmf0MarkerReference:
            return [TVUIRLAmfValue referenceValue];
        case TVUIRLAmf0MarkerEcmaArray: {
            NSDictionary *o = [self decodeEcmaArrayValue:error];
            if (!o) return nil;
            return [TVUIRLAmfValue ecmaArrayValue:o];
        }
        case TVUIRLAmf0MarkerStrictArray: {
            NSArray *arr = [self decodeStrictArrayValue:error];
            if (!arr) return nil;
            return [TVUIRLAmfValue strictArrayValue:arr];
        }
        case TVUIRLAmf0MarkerDate: {
            NSDate *d = [self decodeDateValue:error];
            if (!d) return nil;
            return [TVUIRLAmfValue dateValue:d];
        }
        case TVUIRLAmf0MarkerLongString: {
            NSString *s = [self decodeLongStringValue:error];
            if (!s) return nil;
            return [TVUIRLAmfValue stringValue:s];
        }
        case TVUIRLAmf0MarkerUnsupported:
            return [TVUIRLAmfValue unsupportedValue];
        case TVUIRLAmf0MarkerXmlDocument: {
            NSString *s = [self decodeLongStringValue:error];
            if (!s) return nil;
            return [TVUIRLAmfValue xmlDocumentValue:s];
        }
        case TVUIRLAmf0MarkerTypedObject: {
            NSString *typeName = [self decodeShortStringValue:error];
            if (!typeName) return nil;
            NSDictionary *o = [self decodeObjectValue:error];
            if (!o) return nil;
            return [TVUIRLAmfValue typedObjectValue:o type:typeName];
        }
        case TVUIRLAmf0MarkerAvmplush:
            return [TVUIRLAmfValue avmplushValue];
        case TVUIRLAmf0MarkerObjectEnd:
            if (error) *error = amfError(TVUIRLAmfDecoderErrorUnexpectedObjectEnd, @"Unexpected object end");
            return nil;
    }
    return nil;
}

- (BOOL)decodeInt:(int *)outValue error:(NSError **)error {
    TVUIRLAmf0Marker marker;
    if (![self readMarker:&marker error:error]) return NO;
    if (marker != TVUIRLAmf0MarkerNumber) {
        if (error) *error = amfError(TVUIRLAmfDecoderErrorNotNumber, @"Expected number");
        return NO;
    }
    double v = 0;
    if (![self readDouble:&v error:error]) return NO;
    *outValue = (int)v;
    return YES;
}

- (nullable NSString *)decodeStringWithError:(NSError **)error {
    TVUIRLAmf0Marker marker;
    if (![self readMarker:&marker error:error]) return nil;
    switch (marker) {
        case TVUIRLAmf0MarkerString:
            return [self decodeShortStringValue:error];
        case TVUIRLAmf0MarkerLongString:
            return [self decodeLongStringValue:error];
        default:
            if (error) *error = amfError(TVUIRLAmfDecoderErrorNotString, @"Expected string");
            return nil;
    }
}

- (nullable NSDictionary<NSString *, TVUIRLAmfValue *> *)decodeObjectWithError:(NSError **)error {
    TVUIRLAmf0Marker marker;
    if (![self readMarker:&marker error:error]) return nil;
    switch (marker) {
        case TVUIRLAmf0MarkerNull:
            return @{};
        case TVUIRLAmf0MarkerObject:
            return [self decodeObjectValue:error];
        default:
            if (error) *error = amfError(TVUIRLAmfDecoderErrorNotObject, @"Expected object");
            return nil;
    }
}

@end
