//
//  TVUIRLPreviewController.h
//  DJIStreamDemo
//
//  AVSampleBufferDisplayLayer 版本的预览控制器, 直接消费解码后的 CMSampleBuffer.
//  替代原 Metal (MTKView + custom YUV→RGB shader) 实现, 渲染走 CoreAnimation 硬件路径.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLPreviewController : NSObject

/// 内部承载 AVSampleBufferDisplayLayer 的 UIView, 调用方加到 view 层级即可显示.
@property (nonatomic, strong, readonly) UIView *view;

- (instancetype)init;

/// 推荐入口: 直接送 RTMPServer 解码后的 sampleBuffer, 内部标记为 DisplayImmediately,
/// 渲染最新可用帧, 不做时间戳排程, 与原 Metal "始终画最新一帧" 行为对齐.
- (void)updateSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/// 兼容入口: 仅有 CVPixelBufferRef 时包成 sampleBuffer 后送显. 用于 zero-copy 回调路径.
- (void)updateFrame:(CVPixelBufferRef)pixelBuffer;

/// 立即清屏, 用于 stop / 关闭 preview 开关.
- (void)clearFrame;

@end

NS_ASSUME_NONNULL_END
