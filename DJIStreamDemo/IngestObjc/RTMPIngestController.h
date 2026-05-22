//
//  RTMPIngestController.h
//  DJIStreamDemo
//
//  Thin wrapper around TVUIRLStreamingServer. 预览改用 AVSampleBufferDisplayLayer.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "TVUIRLTransport.h"
#import "TVUIRLBandwidthMeter.h"

NS_ASSUME_NONNULL_BEGIN

@class RTMPIngestController;

@protocol RTMPIngestControllerDelegate <NSObject>
@optional
- (void)rtmpIngestDidStartPublishWithStreamKey:(NSString *)streamKey;
- (void)rtmpIngestDidStopPublishWithStreamKey:(NSString *)streamKey reason:(NSString *)reason;
@end

@interface RTMPIngestController : NSObject

@property (class, nonatomic, readonly) RTMPIngestController *shared;

@property (nonatomic, weak, nullable) id<RTMPIngestControllerDelegate> delegate;

/// 预览渲染面板。把它加入你的视图层级即可显示解码后的视频。
@property (nonatomic, strong, readonly) UIView *previewView;

/// 缓冲延迟（毫秒），加在每帧 PTS 上。0 = 解码后立即渲染。默认 0。
@property (nonatomic, assign) int32_t latency;

/// TCP_NODELAY（关闭 Nagle）。低延迟时保持开启。默认 YES。
@property (nonatomic, assign) BOOL noDelay;

/// 兼容字段，已废弃；display layer 直接渲染最新帧无需中间队列。
@property (nonatomic, assign) NSInteger frameQueueSize;

/// 当前使用的 socket 后端。默认 Network.framework；可在调用 start 前修改以做对比。
@property (nonatomic, assign) TVUIRLTransportBackend backend;

/// 是否把解码后帧送到 preview layer. 默认 YES.
/// 关掉之后 video 回调里直接 return, 不走 sampleBuffer → display layer 路径,
/// 用于隔离测量 server + 解码 路径的纯 CPU 开销 (排除 preview 渲染).
/// nonatomic: UI 线程写 / server 回调线程读, BOOL 单字节读写天然原子, 无需 atomic 锁.
@property (nonatomic, assign) BOOL previewEnabled;

/// 启动 RTMP 服务监听 port，接受 streamKey。多次调用安全，会先 stop 旧会话。
- (void)startWithPort:(uint16_t)port streamKey:(NSString *)streamKey;
- (void)stop;
- (BOOL)isRunning;
- (TVUIRLBandwidthSnapshot)updateStats;

@end

NS_ASSUME_NONNULL_END
