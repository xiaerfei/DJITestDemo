//
//  TVUIRLByteIO.h
//  DJIStreamDemo
//
//  DJI 协议帧编解码用的字节流读写工具。
//
//  设计目的：
//    - DJI 私有协议字段都是小端（Little Endian），且包含 24 位整数（unusual size）
//    - NSData 直接操作不够顺手，封装一层带"光标位置"的读取器和顺序写入器更直观
//
//  注意：这是从 Swift 版的 ByteReader / ByteWriter 移植过来的最小子集，
//  只实现了 DJI 协议会用到的 6 个方法。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ByteIO 错误域
extern NSErrorDomain const TVUIRLByteIOErrorDomain;

/// ByteIO 错误码
typedef NS_ERROR_ENUM(TVUIRLByteIOErrorDomain, TVUIRLByteIOError) {
    /// 试图读取超出剩余可读字节数的数据
    TVUIRLByteIOErrorOutOfBounds = 1,
};

#pragma mark - ByteReader

/// 顺序读取器：在内部维护一个光标 position，从 data 中按字段大小依次读出。
@interface TVUIRLByteReader : NSObject

/// 当前还可以读取的字节数（= data.length - position）
@property (nonatomic, readonly) NSUInteger bytesAvailable;

/// 当前光标位置
@property (nonatomic, readonly) NSUInteger position;

/// 从给定数据创建读取器，光标从 0 开始。
- (instancetype)initWithData:(NSData *)data;

/// 读 1 字节无符号整数，并把光标前移 1。
- (BOOL)readUInt8:(uint8_t *)outValue error:(NSError **)error;

/// 读 2 字节小端无符号整数，并把光标前移 2。
- (BOOL)readUInt16Le:(uint16_t *)outValue error:(NSError **)error;

/// 读 3 字节小端无符号整数（DJI 的 type 字段是 24 位），并把光标前移 3。
- (BOOL)readUInt24Le:(uint32_t *)outValue error:(NSError **)error;

/// 读 count 个字节作为 NSData 切片，并把光标前移 count。
- (nullable NSData *)readBytes:(NSUInteger)count error:(NSError **)error;

@end

#pragma mark - ByteWriter

/// 顺序写入器：内部维护一个 NSMutableData，每次调用都向尾部追加。
@interface TVUIRLByteWriter : NSObject

/// 当前已写入的所有字节
@property (nonatomic, readonly) NSData *data;

- (instancetype)init;

/// 追加 1 字节
- (void)writeUInt8:(uint8_t)value;

/// 追加 2 字节小端整数（低字节在前）
- (void)writeUInt16Le:(uint16_t)value;

/// 追加 3 字节小端整数
- (void)writeUInt24Le:(uint32_t)value;

/// 追加任意字节序列
- (void)writeBytes:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
