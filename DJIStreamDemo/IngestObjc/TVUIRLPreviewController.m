//
//  TVUIRLPreviewController.m
//  DJIStreamDemo
//

#import "TVUIRLPreviewController.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark - DisplayLayerView

/// 承载 AVSampleBufferDisplayLayer 的 UIView. 用 +layerClass 让 view.layer 本身
/// 就是 display layer, 省一次 sublayer 添加和 frame 同步, 也避免 layoutSubviews 时
/// 漏 sync sublayer.frame 导致黑屏.
@interface TVUIRLPreviewDisplayView : UIView
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@end

@implementation TVUIRLPreviewDisplayView

+ (Class)layerClass {
    return [AVSampleBufferDisplayLayer class];
}

- (AVSampleBufferDisplayLayer *)displayLayer {
    return (AVSampleBufferDisplayLayer *)self.layer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        // 黑底, 保持与原 MTKView 视觉一致 (无内容时显示黑屏而非系统默认背景).
        self.backgroundColor = [UIColor blackColor];
        // 保持原 Metal 版本的 letterbox 行为: 视频按比例 fit, 上下/左右留黑边.
        self.displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    }
    return self;
}

@end

#pragma mark - TVUIRLPreviewController

@interface TVUIRLPreviewController ()
@property (nonatomic, strong, readwrite) UIView *view;
@property (nonatomic, strong) TVUIRLPreviewDisplayView *displayView;
/// 缓存的 CMVideoFormatDescription, 用于把裸 CVPixelBuffer 包成 CMSampleBuffer.
/// 仅当 PixelBuffer 的 width/height/pixelFormat 变化时重建, 避免每帧一次创建.
@property (nonatomic, assign) CMVideoFormatDescriptionRef cachedFormatDesc;
@property (nonatomic, assign) size_t cachedWidth;
@property (nonatomic, assign) size_t cachedHeight;
@property (nonatomic, assign) OSType cachedPixelFormat;
@end

@implementation TVUIRLPreviewController

- (instancetype)init {
    if (self = [super init]) {
        _displayView = [[TVUIRLPreviewDisplayView alloc] initWithFrame:CGRectZero];
        _view = _displayView;
    }
    return self;
}

- (void)dealloc {
    if (_cachedFormatDesc) {
        CFRelease(_cachedFormatDesc);
        _cachedFormatDesc = NULL;
    }
}

#pragma mark - Public

- (void)updateSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL) return;
    [self enqueueSampleBuffer:sampleBuffer];
}

- (void)updateFrame:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == NULL) return;
    CMSampleBufferRef sampleBuffer = [self sampleBufferFromPixelBuffer:pixelBuffer];
    if (sampleBuffer == NULL) return;
    [self enqueueSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);
}

- (void)clearFrame {
    AVSampleBufferDisplayLayer *layer = self.displayView.displayLayer;
    // flushAndRemoveImage 同时清掉队列里待显示的帧和当前显示的最后一帧, 用户体验上"立即黑屏".
    if ([layer respondsToSelector:@selector(flushAndRemoveImage)]) {
        [layer flushAndRemoveImage];
    } else {
        [layer flush];
    }
}

#pragma mark - Private

/// 把 sampleBuffer 标记为 DisplayImmediately 后 enqueue. 出错(layer.status==failed) 时 flush 重启.
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    AVSampleBufferDisplayLayer *layer = self.displayView.displayLayer;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        // layer 进入 failed 后必须 flush 才能恢复; 常见原因是连续大量帧没消费完导致 OOM.
        [layer flush];
    }
    [self markDisplayImmediately:sampleBuffer];
    [layer enqueueSampleBuffer:sampleBuffer];
}

/// 把 sampleBuffer 的 attachments[0] 标记为 DisplayImmediately, 让 layer 不按 PTS 排程,
/// 收到一帧就显示一帧 —— 与原 Metal "drawInMTKView 始终画 latestPixelBuffer" 行为一致.
- (void)markDisplayImmediately:(CMSampleBufferRef)sampleBuffer {
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, /*create=*/true);
    if (attachmentsArray == NULL || CFArrayGetCount(attachmentsArray) == 0) {
        return;
    }
    CFMutableDictionaryRef dict =
        (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
}

/// 把 CVPixelBuffer 包成 CMSampleBuffer. PTS 用 kCMTimeInvalid + DisplayImmediately, 不影响排程.
/// 调用方需要 CFRelease 返回值.
- (CMSampleBufferRef)sampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer CF_RETURNS_RETAINED {
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

    // 复用 CMVideoFormatDescription, 仅在尺寸/格式变化时重建.
    if (self.cachedFormatDesc == NULL
        || width != self.cachedWidth
        || height != self.cachedHeight
        || pixelFormat != self.cachedPixelFormat) {
        if (self.cachedFormatDesc) {
            CFRelease(self.cachedFormatDesc);
            self.cachedFormatDesc = NULL;
        }
        CMVideoFormatDescriptionRef desc = NULL;
        OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault, pixelBuffer, &desc);
        if (status != noErr || desc == NULL) {
            return NULL;
        }
        self.cachedFormatDesc = desc;
        self.cachedWidth = width;
        self.cachedHeight = height;
        self.cachedPixelFormat = pixelFormat;
    }

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = kCMTimeInvalid,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        /*dataReady=*/true,
        /*makeDataReadyCallback=*/NULL,
        /*makeDataReadyRefcon=*/NULL,
        self.cachedFormatDesc,
        &timing,
        &sampleBuffer);
    if (status != noErr || sampleBuffer == NULL) {
        return NULL;
    }
    return sampleBuffer;
}

@end
