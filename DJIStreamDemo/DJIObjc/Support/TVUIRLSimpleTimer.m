//
//  TVUIRLSimpleTimer.m
//  DJIStreamDemo
//

#import "TVUIRLSimpleTimer.h"

@implementation TVUIRLSimpleTimer {
    dispatch_queue_t _queue;     // 计时器回调使用的队列
    dispatch_source_t _timer;    // 当前活动的计时器源（GCD 对象，nil 表示空闲）
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _queue = queue;
    }
    return self;
}

- (void)dealloc {
    // 防止对象释放后回调还在排队
    [self stop];
}

- (void)startSingleShotWithTimeout:(NSTimeInterval)timeout
                           handler:(dispatch_block_t)handler {
    [self stop];  // 先停掉旧的

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    // 单次计时：interval 设为 DISPATCH_TIME_FOREVER
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              0);
    dispatch_source_set_event_handler(t, handler);
    dispatch_resume(t);
    _timer = t;
}

- (void)startPeriodicWithInterval:(NSTimeInterval)interval
                          initial:(NSTimeInterval)initial
                          handler:(dispatch_block_t)handler {
    [self stop];

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(initial * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC),
                              0);
    dispatch_source_set_event_handler(t, handler);
    dispatch_resume(t);
    _timer = t;
}

- (void)stop {
    if (_timer) {
        // dispatch_source_cancel 会让 source 进入 cancelled 状态，
        // 不会再触发 event handler，且 GCD 会自动释放底层资源。
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

@end
