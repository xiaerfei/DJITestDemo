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

@interface TVUIRLStreamConnection : NSObject

@property (nonatomic, weak, readonly) TVUIRLStreamingServer *server;
@property (nonatomic, copy) NSString *streamKey;
@property (nonatomic, assign) int32_t latency;
@property (nonatomic, copy) NSUUID *cameraId;
@property (nonatomic, assign) NSInteger chunkSizeFromClient;
@property (nonatomic, assign) NSInteger chunkSizeToClient;
@property (nonatomic, assign) NSInteger windowAcknowledgementSize;
@property (nonatomic, assign) TVUIRLConnectionLifecycle lifecycle;
@property (nonatomic, strong, readonly) NSDate *latestReceiveTime;

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
