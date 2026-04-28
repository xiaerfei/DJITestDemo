//
//  TVUIRLMediaPipeline.h
//  DJIStreamDemo
//
//  单个 chunk stream id 的消息处理管道：解析 AMF/控制/视频/音频 消息。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TVUIRLStreamConnection;

@interface TVUIRLMediaPipeline : NSObject

/// 来自客户端的 type 字段
@property (nonatomic, assign) uint8_t messageTypeId;
/// 当前消息长度（chunk 头中读取）
@property (nonatomic, assign) NSInteger messageLength;
/// chunk 中的时间戳
@property (nonatomic, assign) uint32_t messageTimestamp;
/// chunk 中的 stream id
@property (nonatomic, assign) uint32_t messageStreamId;
/// 是否绝对时间戳
@property (nonatomic, assign) BOOL isAbsoluteTimestamp;
/// 在 type 3 中是否需要再读 4 字节扩展时间戳
@property (nonatomic, assign) BOOL extendedTimestampPresentInType3;

- (instancetype)initWithConnection:(TVUIRLStreamConnection *)connection
                            chunkStreamId:(uint16_t)chunkStreamId NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)stop;

/// 当前消息还需要多少字节
- (NSInteger)remainingMessageBytes;
/// 单个 chunk data 长度 = min(chunkSizeFromClient, remaining)
- (NSInteger)nextChunkDataSize;
/// 接收到的 chunk data 追加到消息体；满消息时触发 process。
- (void)appendChunkData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
