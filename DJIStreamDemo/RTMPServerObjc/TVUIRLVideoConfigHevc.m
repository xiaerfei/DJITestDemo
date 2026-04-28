//
//  TVUIRLVideoConfigHevc.m
//  DJIStreamDemo
//

#import "TVUIRLVideoConfigHevc.h"
#import "TVUIRLDataReader.h"

@interface TVUIRLVideoConfigHevc ()
@property (nonatomic, copy, nullable, readwrite) NSData *videoParameterSet;
@property (nonatomic, copy, nullable, readwrite) NSData *sequenceParameterSet;
@property (nonatomic, copy, nullable, readwrite) NSData *pictureParameterSet;
@end

@implementation TVUIRLVideoConfigHevc

- (instancetype)initWithHvcC:(NSData *)hvcC {
    if (self = [super init]) {
        TVUIRLDataReader *reader = [[TVUIRLDataReader alloc] initWithData:hvcC];
        NSError *error = nil;
        if (![reader skipBytes:22 error:&error]) return self;
        uint8_t numberOfArrays = 0;
        if (![reader readUInt8:&numberOfArrays error:&error]) return self;
        for (uint8_t i = 0; i < numberOfArrays; i++) {
            uint8_t header = 0;
            if (![reader readUInt8:&header error:&error]) return self;
            uint8_t nalUnitType = header & 0b00111111;
            uint16_t numNalus = 0;
            if (![reader readUInt16:&numNalus error:&error]) return self;
            for (uint16_t j = 0; j < numNalus; j++) {
                uint16_t length = 0;
                if (![reader readUInt16:&length error:&error]) return self;
                NSData *data = [reader readBytesOfLength:length error:&error];
                if (!data) return self;
                switch (nalUnitType) {
                    case TVUIRLHevcNalUnitTypeVps:
                        self.videoParameterSet = data;
                        break;
                    case TVUIRLHevcNalUnitTypeSps:
                        self.sequenceParameterSet = data;
                        break;
                    case TVUIRLHevcNalUnitTypePps:
                        self.pictureParameterSet = data;
                        break;
                    default:
                        break;
                }
            }
        }
    }
    return self;
}

- (OSStatus)makeFormatDescription:(CMVideoFormatDescriptionRef _Nullable * _Nonnull)formatDescriptionOut {
    if (!self.videoParameterSet || !self.sequenceParameterSet || !self.pictureParameterSet) {
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    }
    const uint8_t *vpsPtr = self.videoParameterSet.bytes;
    const uint8_t *spsPtr = self.sequenceParameterSet.bytes;
    const uint8_t *ppsPtr = self.pictureParameterSet.bytes;
    const uint8_t * const pointers[3] = { vpsPtr, spsPtr, ppsPtr };
    const size_t sizes[3] = {
        self.videoParameterSet.length,
        self.sequenceParameterSet.length,
        self.pictureParameterSet.length
    };
    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault,
        3,
        pointers,
        sizes,
        4,
        NULL,
        formatDescriptionOut
    );
}

@end
