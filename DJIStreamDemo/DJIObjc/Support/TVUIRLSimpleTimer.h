//
//  TVUIRLSimpleTimer.h
//  DJIStreamDemo
//
//  对 dispatch_source_t 的轻量封装，比 NSTimer 更灵活：
//    - 可指定执行队列（NSTimer 必须在 RunLoop 上）
//    - 不依赖 RunLoop，避免回调期间被业务卡住
//    - 单次和周期性两种用法
//
//  本工程主要用于"启动流超时"和"停止流超时"两个看门狗计时器。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLSimpleTimer : NSObject

/// 创建一个绑定到指定队列的计时器（handler 会在该队列回调）。
- (instancetype)initWithQueue:(dispatch_queue_t)queue;

/// 启动单次计时：timeout 秒后执行 handler 一次。
/// 重复调用会先停止已有计时器，再启动新的。
- (void)startSingleShotWithTimeout:(NSTimeInterval)timeout
                           handler:(dispatch_block_t)handler;

/// 启动周期计时：第一次 initial 秒后触发，之后每 interval 秒触发一次。
- (void)startPeriodicWithInterval:(NSTimeInterval)interval
                          initial:(NSTimeInterval)initial
                          handler:(dispatch_block_t)handler;

/// 停止当前计时器（如果还在运行）。dealloc 时也会自动调用。
- (void)stop;

@end

NS_ASSUME_NONNULL_END
