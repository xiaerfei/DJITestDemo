//
//  RTMPIngestController.h
//  DJIStreamDemo
//
//  Thin wrapper around tvu_irl_streaming_server (纯 C 实现)。
//  预览改用 AVSampleBufferDisplayLayer。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "tvu_irl_bandwidth_meter.h"

NS_ASSUME_NONNULL_BEGIN

/// 兼容旧 ObjC 名字，方便 ViewController 等外部代码不动。
typedef tvu_irl_bandwidth_snapshot_t TVUIRLBandwidthSnapshot;

@class RTMPIngestController;

@protocol RTMPIngestControllerDelegate <NSObject>
@optional
- (void)rtmpIngestDidStartPublishWithStreamKey:(NSString *)streamKey;
- (void)rtmpIngestDidStopPublishWithStreamKey:(NSString *)streamKey reason:(NSString *)reason;
@end

@interface RTMPIngestController : NSObject

@property (class, nonatomic, readonly) RTMPIngestController *shared;

@property (nonatomic, weak, nullable) id<RTMPIngestControllerDelegate> delegate;

/// 预览渲染面板。
@property (nonatomic, strong, readonly) UIView *previewView;

/// 缓冲延迟（毫秒），加在每帧 PTS 上。0 = 解码后立即渲染。默认 0。
@property (nonatomic, assign) int32_t latency;

/// TCP_NODELAY（关闭 Nagle）。默认 YES。
@property (nonatomic, assign) BOOL noDelay;

/// 兼容字段，已废弃。
@property (nonatomic, assign) NSInteger frameQueueSize;

/// 是否把解码后帧送到 preview layer。默认 YES。
@property (nonatomic, assign) BOOL previewEnabled;

- (void)startWithPort:(uint16_t)port streamKey:(NSString *)streamKey;
- (void)stop;
- (BOOL)isRunning;
- (TVUIRLBandwidthSnapshot)updateStats;

@end

NS_ASSUME_NONNULL_END
