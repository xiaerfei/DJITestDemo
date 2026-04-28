//
//  TVUIRLAmfDecoder.h
//  DJIStreamDemo
//
//  AMF0 解码器（Data → 值）。继承 TVUIRLDataReader 复用字节读取。
//

#import "TVUIRLDataReader.h"
#import "TVUIRLAmfValue.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const TVUIRLAmfDecoderErrorDomain;

typedef NS_ERROR_ENUM(TVUIRLAmfDecoderErrorDomain, TVUIRLAmfDecoderError) {
    TVUIRLAmfDecoderErrorArrayTooBig = 1,
    TVUIRLAmfDecoderErrorNotObjectEnd = 2,
    TVUIRLAmfDecoderErrorUnexpectedObjectEnd = 3,
    TVUIRLAmfDecoderErrorNotNumber = 4,
    TVUIRLAmfDecoderErrorNotString = 5,
    TVUIRLAmfDecoderErrorNotObject = 6,
    TVUIRLAmfDecoderErrorNotAmf0 = 7,
};

@interface TVUIRLAmfDecoder : TVUIRLDataReader

- (nullable TVUIRLAmfValue *)decodeWithError:(NSError **)error;
- (BOOL)decodeInt:(int *)outValue error:(NSError **)error;
- (nullable NSString *)decodeStringWithError:(NSError **)error;
- (nullable NSDictionary<NSString *, TVUIRLAmfValue *> *)decodeObjectWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
