//
//  TVUIRLVideoConfigAvc.m
//  DJIStreamDemo
//

#import "TVUIRLVideoConfigAvc.h"
#import "TVUIRLDataReader.h"

static const uint8_t kAvcReservedNumOfSps = 0xE0;

@interface TVUIRLVideoConfigAvc ()
@property (nonatomic, copy, nullable, readwrite) NSData *sequenceParameterSet;
@property (nonatomic, copy, nullable, readwrite) NSData *pictureParameterSet;
@end

@implementation TVUIRLVideoConfigAvc

- (instancetype)initWithAvcC:(NSData *)avcC {
    if (self = [super init]) {
        TVUIRLDataReader *reader = [[TVUIRLDataReader alloc] initWithData:avcC];
        NSError *error = nil;
        if (![reader skipBytes:5 error:&error]) return self;
        uint8_t numOfSpsWithReserved = 0;
        if (![reader readUInt8:&numOfSpsWithReserved error:&error]) return self;
        uint8_t numOfSps = numOfSpsWithReserved & ~kAvcReservedNumOfSps;
        for (uint8_t i = 0; i < numOfSps; i++) {
            uint16_t length = 0;
            if (![reader readUInt16:&length error:&error]) return self;
            NSData *sps = [reader readBytesOfLength:length error:&error];
            if (!sps) return self;
            self.sequenceParameterSet = sps;
        }
        uint8_t numOfPps = 0;
        if (![reader readUInt8:&numOfPps error:&error]) return self;
        for (uint8_t i = 0; i < numOfPps; i++) {
            uint16_t length = 0;
            if (![reader readUInt16:&length error:&error]) return self;
            NSData *pps = [reader readBytesOfLength:length error:&error];
            if (!pps) return self;
            self.pictureParameterSet = pps;
        }
    }
    return self;
}

- (OSStatus)makeFormatDescription:(CMVideoFormatDescriptionRef _Nullable * _Nonnull)formatDescriptionOut {
    if (!self.sequenceParameterSet || !self.pictureParameterSet) {
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    }
    const uint8_t *spsPtr = self.sequenceParameterSet.bytes;
    const uint8_t *ppsPtr = self.pictureParameterSet.bytes;
    const uint8_t * const pointers[2] = { spsPtr, ppsPtr };
    const size_t sizes[2] = { self.sequenceParameterSet.length, self.pictureParameterSet.length };
    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        2,
        pointers,
        sizes,
        4,
        formatDescriptionOut
    );
}

@end
