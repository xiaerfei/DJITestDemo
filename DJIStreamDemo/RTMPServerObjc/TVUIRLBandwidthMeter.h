//
//  TVUIRLBandwidthMeter.h
//  DJIStreamDemo
//
//  RTMP 输入码率统计：累计字节数 + 平滑后的瞬时速度（bytes/s）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uint64_t total;
    uint64_t speed;
} TVUIRLBandwidthSnapshot;

@interface TVUIRLBandwidthMeter : NSObject

@property (nonatomic, readonly) uint64_t totalBytes;
@property (nonatomic, readonly) uint64_t latestSpeed;

- (instancetype)init;
- (instancetype)initWithSpeedChangeRate:(uint64_t)speedChangeRate NS_DESIGNATED_INITIALIZER;

- (void)addBytesTransferred:(NSInteger)bytes;
- (TVUIRLBandwidthSnapshot)update;

@end

NS_ASSUME_NONNULL_END
