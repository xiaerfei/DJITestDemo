//
//  TVUIRLStreamingServer.h
//  DJIStreamDemo
//
//  RTMP 接收服务器主入口。监听 TCP，每个连接构建 TVUIRLStreamConnection。
//  通过 delegate 回调推流开始/结束、视频/音频 CMSampleBuffer、统计信息。
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "TVUIRLStreamConfig.h"
#import "TVUIRLBandwidthMeter.h"
#import "TVUIRLTransport.h"

NS_ASSUME_NONNULL_BEGIN

@class TVUIRLStreamingServer;

@protocol TVUIRLStreamingServerDelegate <NSObject>
- (void)server:(TVUIRLStreamingServer *)server didStartPublishingStream:(NSString *)streamKey;
- (void)server:(TVUIRLStreamingServer *)server didStopPublishingStream:(NSString *)streamKey reason:(NSString *)reason;
- (void)server:(TVUIRLStreamingServer *)server didReceiveVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)server:(TVUIRLStreamingServer *)server didReceiveAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@optional
- (void)server:(TVUIRLStreamingServer *)server didReceiveVideoImageBuffer:(CVImageBufferRef)imageBuffer;
- (void)server:(TVUIRLStreamingServer *)server didUpdateStats:(TVUIRLBandwidthSnapshot)snapshot;
- (void)server:(TVUIRLStreamingServer *)server
   didUpdateTargetVideoLatency:(double)videoLatency
                  audioLatency:(double)audioLatency;
@end

@interface TVUIRLStreamingServer : NSObject

@property (nonatomic, weak, nullable) id<TVUIRLStreamingServerDelegate> delegate;
@property (nonatomic, copy, readonly) TVUIRLStreamConfig *config;
@property (nonatomic, readonly) TVUIRLTransportBackend backend;

/// 默认使用 Network.framework 后端。
- (instancetype)initWithConfig:(TVUIRLStreamConfig *)config;
/// 显式指定 socket 后端，便于对比。
- (instancetype)initWithConfig:(TVUIRLStreamConfig *)config
                       backend:(TVUIRLTransportBackend)backend NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
- (void)stop;

- (BOOL)isStreamConnected:(NSString *)streamKey;
- (NSInteger)numberOfClients;
- (TVUIRLBandwidthSnapshot)updateStats;

@end

NS_ASSUME_NONNULL_END
