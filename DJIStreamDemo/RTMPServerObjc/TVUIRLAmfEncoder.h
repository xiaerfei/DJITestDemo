//
//  TVUIRLAmfEncoder.h
//  DJIStreamDemo
//
//  AMF0 编码器（值 → Data）。继承 TVUIRLDataWriter 复用字节写入。
//

#import "TVUIRLDataWriter.h"
#import "TVUIRLAmfValue.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLAmfEncoder : TVUIRLDataWriter

- (void)encodeValue:(TVUIRLAmfValue *)value;

@end

NS_ASSUME_NONNULL_END
