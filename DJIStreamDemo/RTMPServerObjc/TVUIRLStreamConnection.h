//
//  TVUIRLStreamConnection.h
//  DJIStreamDemo
//
//  单个 RTMP 客户端连接：含握手与 chunk 拆解状态机。
//  通过 id<TVUIRLTransportConnection> 与具体 socket 库（Network.framework / GCDAsyncSocket）解耦。
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "TVUIRLTransport.h"

NS_ASSUME_NONNULL_BEGIN

@class TVUIRLStreamingServer;
@class TVUIRLMediaPacket;

typedef NS_ENUM(NSInteger, TVUIRLConnectionLifecycle) {
    TVUIRLConnectionLifecycleIdle,
    TVUIRLConnectionLifecycleConnecting,
    TVUIRLConnectionLifecycleConnected,
};

/// 解码出口 PTS 重锚协议：把每路解码后的 PTS 重写到 host time 域，吃掉解码异步耗时引入的偏置。
/// 视频/音频分别锚自己的 firstPts；basetime 整个会话首次锚定后两路共享。
/// 实现方需保证线程安全（VT 回调线程与 RTMP socket 线程会并发调用）。
@protocol TVUIRLDecodedPtsAnchor <NSObject>
- (CMTime)remapVideoDecodedPts:(CMTime)pts;
- (CMTime)remapAudioDecodedPts:(CMTime)pts;
@end

@interface TVUIRLStreamConnection : NSObject <TVUIRLDecodedPtsAnchor>

@property (nonatomic, weak, readonly) TVUIRLStreamingServer *server;
@property (nonatomic, copy) NSString *streamKey;
@property (nonatomic, assign) int32_t latency;
@property (nonatomic, copy) NSUUID *cameraId;
@property (nonatomic, assign) NSInteger chunkSizeFromClient;
@property (nonatomic, assign) NSInteger chunkSizeToClient;
@property (nonatomic, assign) NSInteger windowAcknowledgementSize;
@property (nonatomic, assign) TVUIRLConnectionLifecycle lifecycle;
@property (nonatomic, assign, readonly) CFAbsoluteTime latestReceiveAbsTime;
/// 视频 pipeline 最新一帧的 RTMP 时间戳（相对 mediaTimestampZero，ms）。
/// 供音频侧对比 A/V RTMP 时间戳差值；两个 pipeline 跨线程访问，声明为 atomic。
@property (atomic, assign) double lastVideoRtmpTs;

- (instancetype)initWithServer:(TVUIRLStreamingServer *)server
                     transport:(id<TVUIRLTransportConnection>)transport NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
- (void)stopWithReason:(NSString *)reason;

- (void)sendMessagePacket:(TVUIRLMediaPacket *)packet;

#pragma mark - Pipeline callbacks

- (void)pipelineDidProduceVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)pipelineDidProduceVideoImageBuffer:(CVImageBufferRef)imageBuffer;
- (void)pipelineDidProduceAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)pipelineDidObserveAudioPts:(double)pts;
- (void)pipelineDidObserveVideoPts:(double)pts;

- (double)basePresentationTimeStampMs;

@end

NS_ASSUME_NONNULL_END
