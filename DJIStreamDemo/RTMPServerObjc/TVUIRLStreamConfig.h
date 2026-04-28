//
//  TVUIRLStreamConfig.h
//  DJIStreamDemo
//
//  RTMP 服务器配置 + 单个流配置档（streamKey + 延迟）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLStreamProfile : NSObject

@property (nonatomic, copy, readonly) NSUUID *uuid;
@property (nonatomic, copy) NSString *streamKey;
/// 目标延迟，毫秒。
@property (nonatomic, assign) int32_t latency;

- (instancetype)initWithStreamKey:(NSString *)streamKey;
- (instancetype)initWithStreamKey:(NSString *)streamKey latency:(int32_t)latency;
- (instancetype)initWithStreamKey:(NSString *)streamKey latency:(int32_t)latency uuid:(NSUUID *)uuid NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (double)latencySeconds;

@end

@interface TVUIRLStreamConfig : NSObject

@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy) NSArray<TVUIRLStreamProfile *> *streams;
@property (nonatomic, assign) BOOL noDelay;

- (instancetype)init;
- (instancetype)initWithPort:(uint16_t)port streams:(NSArray<TVUIRLStreamProfile *> *)streams noDelay:(BOOL)noDelay NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
