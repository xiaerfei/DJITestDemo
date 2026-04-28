//
//  TVUIRLProtocolMessage.h
//  DJIStreamDemo
//
//  RTMP 协议消息基类，对应 Swift RtmpMessage。
//  子类通过覆盖 -buildEncoded / -parseEncoded: 来惰性编/解码。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, TVUIRLMessageType) {
    TVUIRLMessageTypeChunkSize    = 0x01,
    TVUIRLMessageTypeAbort        = 0x02,
    TVUIRLMessageTypeAck          = 0x03,
    TVUIRLMessageTypeUser         = 0x04,
    TVUIRLMessageTypeWindowAck    = 0x05,
    TVUIRLMessageTypeBandwidth    = 0x06,
    TVUIRLMessageTypeAudio        = 0x08,
    TVUIRLMessageTypeVideo        = 0x09,
    TVUIRLMessageTypeAmf3Data     = 0x0F,
    TVUIRLMessageTypeAmf3Command  = 0x11,
    TVUIRLMessageTypeAmf0Data     = 0x12,
    TVUIRLMessageTypeAmf0Command  = 0x14,
    TVUIRLMessageTypeAggregate    = 0x16,
};

@interface TVUIRLProtocolMessage : NSObject

@property (nonatomic, readonly) TVUIRLMessageType type;
@property (nonatomic, assign) NSInteger length;
@property (nonatomic, assign) uint32_t streamId;
@property (nonatomic, assign) uint32_t timestamp;

/// 序列化后的消息体。读取时若为空会调用 -buildEncoded 惰性构造；
/// 写入时（接收侧）会调用 -parseEncoded:。
@property (nonatomic, copy) NSData *encoded;

- (instancetype)initWithType:(TVUIRLMessageType)type NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Override hooks for subclasses

/// 子类返回根据自身字段构造的 encoded 数据。基类返回空。
- (NSData *)buildEncoded;

/// 子类基于传入字节解析自身字段。基类不做任何事。
- (void)parseEncoded:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
