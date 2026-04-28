//
//  TVUIRLWindowAckMessage.h
//  DJIStreamDemo
//
//  RTMP Window Acknowledgement Size (type 0x05)：4 字节大端 size。
//

#import "TVUIRLProtocolMessage.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLWindowAckMessage : TVUIRLProtocolMessage

@property (nonatomic, assign) uint32_t size;

- (instancetype)init;
- (instancetype)initWithSize:(uint32_t)size;

@end

NS_ASSUME_NONNULL_END
