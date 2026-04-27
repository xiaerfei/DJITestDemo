//
//  TVUIRLDJIMessage.h
//  DJIStreamDemo
//
//  DJI 私有 BLE 协议的"帧"层抽象。
//
//  帧格式（参考 report.md 第 4.3 节）：
//
//      ┌──────┬────────┬──────┬──────────┬─────────┬─────────┬─────────┬───────────┬─────────┐
//      │ 0x55 │ Length │ 0x04 │ HeaderCRC│ Target  │ Id      │ Type    │  Payload  │ CRC16   │
//      │ 1B   │ 1B     │ 1B   │ 1B (CRC8)│ 2B (LE) │ 2B (LE) │ 3B (LE) │ 变长       │ 2B (LE) │
//      └──────┴────────┴──────┴──────────┴─────────┴─────────┴─────────┴───────────┴─────────┘
//        起始    总长度  版本  头部 CRC8     目标 ID  事务 ID    消息类型      载荷       帧体 CRC16
//
//  - HeaderCRC 校验前 3 个字节
//  - CRC16 校验从 0x55 起、到 Payload 末尾的所有字节（不含 CRC16 自身）
//  - Length 包含整帧字节数（13 字节固定字段 + Payload 长度）
//
//  注：该协议是逆向工程出来的，DJI 官方未公开。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 帧解析的错误域
extern NSErrorDomain const TVUIRLDJIMessageErrorDomain;

/// 帧解析错误码
typedef NS_ERROR_ENUM(TVUIRLDJIMessageErrorDomain, TVUIRLDJIMessageError) {
    TVUIRLDJIMessageErrorBadFirstByte = 1,    ///< 起始字节不是 0x55
    TVUIRLDJIMessageErrorBadLength,           ///< 帧长字段与实际长度不一致
    TVUIRLDJIMessageErrorBadVersion,          ///< 版本字节不是 0x04
    TVUIRLDJIMessageErrorHeaderCrcMismatch,   ///< 头部 CRC8 校验失败
    TVUIRLDJIMessageErrorBodyCrcMismatch,     ///< 帧体 CRC16 校验失败
    TVUIRLDJIMessageErrorTruncated,           ///< 数据被截断（不足以读取下一字段）
};

#pragma mark - 字段编码工具函数

/// 将字符串打包为「长度（1 字节）+ UTF-8 数据」的格式。
/// 用于 SSID、密码、PIN 码等带长度前缀的字段。
FOUNDATION_EXPORT NSData *TVUIRLDJIPackString(NSString *value);

/// 将 URL 字符串打包为「长度（1 字节）+ 0x00 + UTF-8 数据」的格式。
/// 这是 DJI 协议针对 RTMP URL 的特殊编码（多了一个保留字节 0x00）。
FOUNDATION_EXPORT NSData *TVUIRLDJIPackUrl(NSString *url);

/// 把字节序列格式化成十六进制字符串（用于日志输出，如 "55 0d 04 a3 ..."）。
FOUNDATION_EXPORT NSString *TVUIRLDJIHexString(NSData *data);

#pragma mark - 帧对象

/// 一条完整的 DJI 协议帧，可以被编码成 NSData，或者从 NSData 解码出来。
@interface TVUIRLDJIMessage : NSObject

/// 目标设备 ID（小端 16 位），不同消息类型使用不同 target 值。
@property (nonatomic, assign) uint16_t target;

/// 事务 ID（小端 16 位）。请求和响应共享同一个 transaction ID，
/// 状态机用它来确认收到的是当前期望的响应。
@property (nonatomic, assign) uint16_t messageId;

/// 消息类型（小端 24 位）。每种命令对应一个固定 type 值。
@property (nonatomic, assign) uint32_t type;

/// 命令载荷（变长字节，由具体消息子类编码）。
@property (nonatomic, copy) NSData *payload;

/// 用各字段构造一个待发送的消息（编码成字节请调用 -encode）。
- (instancetype)initWithTarget:(uint16_t)target
                     messageId:(uint16_t)messageId
                          type:(uint32_t)type
                       payload:(NSData *)payload;

/// 从相机回传的字节序列解析出一条消息。
/// 校验失败、长度错误等都会返回 nil 并填充 error。
- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error;

/// 把当前消息序列化为可发送的字节流（含 CRC8 + CRC16）。
- (NSData *)encode;

/// 调试用的人类可读描述，例如：
/// "target: 1794, id: 32914, type: 4523840 20323..."
- (NSString *)format;

@end

NS_ASSUME_NONNULL_END
