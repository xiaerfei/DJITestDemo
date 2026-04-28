//
//  TVUIRLMediaClock.h
//  DJIStreamDemo
//
//  音视频延迟同步：根据最新音/视频 PTS 计算两路目标延迟，使二者对齐。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double audioTargetLatency;
    double videoTargetLatency;
    BOOL hasUpdate;
} TVUIRLMediaClockDecision;

@interface TVUIRLMediaClock : NSObject

- (instancetype)initWithTargetLatency:(double)targetLatency NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)setLatestAudioPresentationTimeStamp:(double)pts;
- (void)setLatestVideoPresentationTimeStamp:(double)pts;

/// 仅当估算差值变化超过 100ms 时返回 hasUpdate=YES，否则返回 NO（不更新调用方）。
- (TVUIRLMediaClockDecision)update;

@end

NS_ASSUME_NONNULL_END
