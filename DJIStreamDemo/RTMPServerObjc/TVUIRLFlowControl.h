//
//  TVUIRLFlowControl.h
//  DJIStreamDemo
//
//  RTMP Set Chunk Size (type 0x01)：4 字节大端 chunk size。
//

#import "TVUIRLProtocolMessage.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLFlowControl : TVUIRLProtocolMessage

@property (nonatomic, assign) uint32_t size;

- (instancetype)init;
- (instancetype)initWithSize:(uint32_t)size;

@end

NS_ASSUME_NONNULL_END
