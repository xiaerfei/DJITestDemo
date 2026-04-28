//
//  TVUIRLStreamingServer+Internal.h
//  DJIStreamDemo
//
//  服务器内部 API：仅供 StreamConnection / MediaPipeline 调用。
//

#import "TVUIRLStreamingServer.h"

NS_ASSUME_NONNULL_BEGIN

@class TVUIRLStreamConnection;

@interface TVUIRLStreamingServer (Internal)

@property (nonatomic, readonly) dispatch_queue_t serverQueue;
@property (nonatomic, readonly) TVUIRLBandwidthMeter *bandwidthMeter;

- (void)connectionDidComplete:(TVUIRLStreamConnection *)connection;
- (void)connectionDidDisconnect:(TVUIRLStreamConnection *)connection reason:(NSString *)reason;

- (void)forwardVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)forwardVideoImageBuffer:(CVImageBufferRef)imageBuffer;
- (void)forwardAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)forwardTargetVideoLatency:(double)videoLatency audioLatency:(double)audioLatency;

@end

NS_ASSUME_NONNULL_END
