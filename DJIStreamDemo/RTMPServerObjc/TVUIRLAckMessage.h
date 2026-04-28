//
//  TVUIRLAckMessage.h
//  DJIStreamDemo
//
//  RTMP Acknowledgement (type 0x03)：4 字节大端 sequence。
//

#import "TVUIRLProtocolMessage.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLAckMessage : TVUIRLProtocolMessage

@property (nonatomic, assign) uint32_t sequence;

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
