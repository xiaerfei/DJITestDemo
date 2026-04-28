//
//  TVUIRLMediaPacket.h
//  DJIStreamDemo
//
//  RTMP Chunk 封装。服务器侧只用于发送方向（编码/拆包）。
//  接收方向由 TVUIRLStreamConnection 状态机直接解析字节流。
//

#import <Foundation/Foundation.h>
#import "TVUIRLProtocolMessage.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, TVUIRLPacketType) {
    TVUIRLPacketTypeZero  = 0,
    TVUIRLPacketTypeOne   = 1,
    TVUIRLPacketTypeTwo   = 2,
    TVUIRLPacketTypeThree = 3,
};

typedef NS_ENUM(uint16_t, TVUIRLChunkStreamId) {
    TVUIRLChunkStreamIdControl = 0x02,
    TVUIRLChunkStreamIdCommand = 0x03,
    TVUIRLChunkStreamIdData    = 0x08,
};

@interface TVUIRLMediaPacket : NSObject

@property (nonatomic, readonly) TVUIRLPacketType type;
@property (nonatomic, readonly) uint16_t chunkStreamId;
@property (nonatomic, strong, readonly) TVUIRLProtocolMessage *message;

- (instancetype)initWithType:(TVUIRLPacketType)type
               chunkStreamId:(uint16_t)chunkStreamId
                     message:(TVUIRLProtocolMessage *)message NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// 拆包：返回若干 Data；若 messageBody 不超过 maximumSize 则只有 1 个，否则后续 chunk 用 Type 3 basic header。
- (NSArray<NSData *> *)splitWithMaximumSize:(NSInteger)maximumSize;

@end

NS_ASSUME_NONNULL_END
