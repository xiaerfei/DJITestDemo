//
//  TVUIRLDataReader.h
//  DJIStreamDemo
//
//  RTMP/AMF 二进制流读取器（Big/Little Endian 全支持），是 TVUIRLAmfDecoder 的父类。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const TVUIRLDataReaderErrorDomain;

typedef NS_ERROR_ENUM(TVUIRLDataReaderErrorDomain, TVUIRLDataReaderError) {
    TVUIRLDataReaderErrorEOF = 1,
    TVUIRLDataReaderErrorUTF8 = 2,
};

@interface TVUIRLDataReader : NSObject

@property (nonatomic, copy, readonly) NSData *data;
@property (nonatomic, assign) NSInteger position;
@property (nonatomic, readonly) NSInteger bytesAvailable;

- (instancetype)initWithData:(NSData *)data NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)readUInt8:(uint8_t *)outValue error:(NSError **)error;
- (BOOL)readUInt16:(uint16_t *)outValue error:(NSError **)error;
- (BOOL)readUInt16Le:(uint16_t *)outValue error:(NSError **)error;
- (BOOL)readUInt24:(uint32_t *)outValue error:(NSError **)error;
- (BOOL)readUInt24Le:(uint32_t *)outValue error:(NSError **)error;
- (BOOL)readUInt32:(uint32_t *)outValue error:(NSError **)error;
- (BOOL)readUInt32Le:(uint32_t *)outValue error:(NSError **)error;
- (BOOL)readDouble:(double *)outValue error:(NSError **)error;
- (nullable NSString *)readUtf8BytesOfLength:(NSInteger)length error:(NSError **)error;
- (nullable NSData *)readBytesOfLength:(NSInteger)length error:(NSError **)error;
- (BOOL)skipBytes:(NSInteger)length error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
