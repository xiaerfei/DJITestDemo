//
//  TVUIRLDataWriter.h
//  DJIStreamDemo
//
//  RTMP/AMF 二进制流写入器（Big/Little Endian 全支持），是 TVUIRLAmfEncoder 的父类。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLDataWriter : NSObject

@property (nonatomic, readonly) NSData *data;
@property (nonatomic, readonly) NSInteger length;

- (instancetype)init;

- (void)writeUInt8:(uint8_t)value;
- (void)writeUInt16:(uint16_t)value;
- (void)writeUInt16Le:(uint16_t)value;
- (void)writeUInt24:(uint32_t)value;
- (void)writeUInt24Le:(uint32_t)value;
- (void)writeUInt32:(uint32_t)value;
- (void)writeUInt32Le:(uint32_t)value;
- (void)writeInt32Be:(int32_t)value;
- (void)writeDouble:(double)value;
- (void)writeUtf8Bytes:(NSString *)value;
- (void)writeBytes:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
