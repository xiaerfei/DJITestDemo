//
//  TVUIRLHardwareDecoder.m
//  DJIStreamDemo
//

#import "TVUIRLHardwareDecoder.h"
#import "TVUIRLDJILog.h"
#import <VideoToolbox/VideoToolbox.h>

// 输出 PTS reorder 缓冲容量上限. 实际深度按流自适应:
//   - PTS == DTS (无 B 帧, 如 DJI 直播): depth=0, 回调直通, 零额外延迟
//   - PTS != DTS (有 B 帧, 如 OBS x264 默认 bframes=3): depth=4, 足够覆盖 3 B + 1 P
// VT 的 kVTDecodeFrame_EnableTemporalProcessing 是 "允许" reorder, 实际依赖 SPS VUI
// 里的 max_num_reorder_frames; OBS x264 经常不写, 所以 VT 直接按 decode order 回调.
// 这里在出口处做一次稳定的 PTS 排序兜底.
static const NSInteger kReorderBufferCapacity = 8;
static const NSInteger kReorderDepthWhenBFramed = 4;

@interface TVUIRLHardwareDecoder () {
    CMSampleBufferRef _reorderBuffer[kReorderBufferCapacity];
    NSInteger _reorderCount;
}
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) VTDecompressionSessionRef session;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDescription;
@property (atomic, assign) NSInteger reorderDepth;
@end

static void decompressionOutputCallback(
    void * CM_NULLABLE decompressionOutputRefCon,
    void * CM_NULLABLE sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CM_NULLABLE CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration);

@implementation TVUIRLHardwareDecoder

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    if (self = [super init]) {
        _queue = queue;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)startWithFormatDescription:(CMVideoFormatDescriptionRef)formatDescription {
    if (!formatDescription) return NO;
    [self stop];
    self.reorderDepth = 0;
    self.formatDescription = (CMVideoFormatDescriptionRef)CFRetain(formatDescription);
    return [self createSession];
}

- (void)stop {
    if (self.session) {
        VTDecompressionSessionWaitForAsynchronousFrames(self.session);
    }
    [self drainReorderBuffer];
    [self invalidateSession];
    if (self.formatDescription) {
        CFRelease(self.formatDescription);
        self.formatDescription = NULL;
    }
}

- (void)decodeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;
    if (!self.session) return;

    // 首次发现 PTS != DTS 即视为存在 B 帧, 打开 reorder buffer. 一旦开启不再关闭,
    // 避免某些 GOP 偶发无 B 帧时来回切换打乱顺序.
    if (self.reorderDepth == 0) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
        if (CMTIME_IS_VALID(pts) && CMTIME_IS_VALID(dts) && CMTimeCompare(pts, dts) != 0) {
            self.reorderDepth = kReorderDepthWhenBFramed;
            TVUIRLDJILog(@"rtmp-server: PTS reorder buffer enabled (depth=%ld, B-frames detected)",
                         (long)kReorderDepthWhenBFramed);
        }
    }

    OSStatus status = [self submitFrame:sampleBuffer];
    // -12903 (kVTInvalidSessionErr): 常见于 App 进入后台时系统回收 VT 资源,
    // 回到前台后第一帧投递就会拿到这个错误. 用保留的 formatDescription 重建 session 后再投一次.
    // 重建后的 session 需要等下一个关键帧才能产出, 中间的 P/B 帧由 VT 内部丢弃 (callback 收 status != noErr 静默 return),
    // DJI 关键帧间隔通常 ≤几秒, 自然恢复.
    if (status == kVTInvalidSessionErr) {
        TVUIRLDJILog(@"rtmp-server: VT session invalidated (-12903), recreating");
        [self invalidateSession];
        if ([self createSession]) {
            status = [self submitFrame:sampleBuffer];
        }
    }
    if (status != noErr) {
        TVUIRLDJILog(@"rtmp-server: VTDecompressionSessionDecodeFrame failed: %d", (int)status);
    }
}

#pragma mark - Private

- (BOOL)createSession {
    if (!self.formatDescription) return NO;
    // 输出格式与主工程相机 kTVUCameraVideoFormat（420v / NV12 video range）保持一致，
    // 让 handleExternalSourceStream 走 "DJI 设备 NV12 直通" 分支，避免 I420ToNV12 误判返回 NULL
    NSDictionary *outputAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    VTDecompressionOutputCallbackRecord cb = {
        .decompressionOutputCallback = decompressionOutputCallback,
        .decompressionOutputRefCon = (__bridge void *)self,
    };
    VTDecompressionSessionRef session = NULL;
    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        self.formatDescription,
        NULL,
        (__bridge CFDictionaryRef)outputAttrs,
        &cb,
        &session);
    if (status != noErr || !session) {
        TVUIRLDJILog(@"rtmp-server: VTDecompressionSessionCreate failed: %d", (int)status);
        return NO;
    }
    self.session = session;
    return YES;
}

- (void)invalidateSession {
    if (self.session) {
        VTDecompressionSessionInvalidate(self.session);
        CFRelease(self.session);
        self.session = NULL;
    }
}

- (OSStatus)submitFrame:(CMSampleBufferRef)sampleBuffer {
    if (!self.session) return kVTInvalidSessionErr;
    // 只开异步; 显示顺序由本类的 reorderBuffer 在回调出口处保证 (不依赖 SPS VUI 信息).
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags infoFlags = 0;
    CMSampleBufferRef retained = (CMSampleBufferRef)CFRetain(sampleBuffer);
    OSStatus status = VTDecompressionSessionDecodeFrame(
        self.session,
        sampleBuffer,
        flags,
        retained,
        &infoFlags);
    if (status != noErr) {
        CFRelease(retained);
    }
    return status;
}

#pragma mark - Reorder buffer

// 把 (已重锚 PTS 的) sampleBuffer 插入 reorder buffer, 必要时弹出当前最小 PTS 一帧给 delegate.
// 调用方负责 release 参数 sb (本方法在需要保留时自己 CFRetain).
- (void)ingestSampleBuffer:(CMSampleBufferRef)sb {
    NSInteger depth = self.reorderDepth;
    if (depth == 0) {
        [self emitSampleBuffer:sb];
        return;
    }

    CMSampleBufferRef toEmit = NULL;
    @synchronized (self) {
        CMTime sbPts = CMSampleBufferGetPresentationTimeStamp(sb);
        NSInteger insertAt = _reorderCount;
        for (NSInteger i = 0; i < _reorderCount; i++) {
            CMTime existing = CMSampleBufferGetPresentationTimeStamp(_reorderBuffer[i]);
            if (CMTimeCompare(sbPts, existing) < 0) { insertAt = i; break; }
        }
        // 容量保护: 万一深度估计不足导致溢出, 强制弹出最小 PTS 那帧避免越界.
        if (_reorderCount >= kReorderBufferCapacity) {
            toEmit = _reorderBuffer[0];
            for (NSInteger i = 1; i < _reorderCount; i++) _reorderBuffer[i - 1] = _reorderBuffer[i];
            _reorderCount--;
            if (insertAt > 0) insertAt--;
        }
        for (NSInteger i = _reorderCount; i > insertAt; i--) _reorderBuffer[i] = _reorderBuffer[i - 1];
        CFRetain(sb);
        _reorderBuffer[insertAt] = sb;
        _reorderCount++;

        if (!toEmit && _reorderCount > depth) {
            toEmit = _reorderBuffer[0];
            for (NSInteger i = 1; i < _reorderCount; i++) _reorderBuffer[i - 1] = _reorderBuffer[i];
            _reorderCount--;
        }
    }

    if (toEmit) {
        [self emitSampleBuffer:toEmit];
        CFRelease(toEmit);
    }
}

- (void)drainReorderBuffer {
    CMSampleBufferRef drained[kReorderBufferCapacity];
    NSInteger count;
    @synchronized (self) {
        count = _reorderCount;
        for (NSInteger i = 0; i < count; i++) {
            drained[i] = _reorderBuffer[i];
            _reorderBuffer[i] = NULL;
        }
        _reorderCount = 0;
    }
    for (NSInteger i = 0; i < count; i++) {
        [self emitSampleBuffer:drained[i]];
        CFRelease(drained[i]);
    }
}

- (void)emitSampleBuffer:(CMSampleBufferRef)sb {
    id<TVUIRLHardwareDecoderDelegate> delegate = self.delegate;
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (img && [delegate respondsToSelector:@selector(hardwareDecoder:didDecodeImageBuffer:)]) {
        [delegate hardwareDecoder:self didDecodeImageBuffer:img];
    }
    if ([delegate respondsToSelector:@selector(hardwareDecoder:didDecodeSampleBuffer:)]) {
        [delegate hardwareDecoder:self didDecodeSampleBuffer:sb];
    }
}

@end

static void decompressionOutputCallback(
    void * decompressionOutputRefCon,
    void * sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration)
{
    (void)infoFlags;
    TVUIRLHardwareDecoder *decoder = (__bridge TVUIRLHardwareDecoder *)decompressionOutputRefCon;
    CMSampleBufferRef sourceSample = (CMSampleBufferRef)sourceFrameRefCon;

    if (status != noErr || !imageBuffer) {
        if (sourceSample) CFRelease(sourceSample);
        return;
    }

    // 构建出口 sampleBuffer (含重锚后的 PTS), 然后送进 reorder buffer 等显示顺序出队.
    // 注: 不再在这里立即直通 imageBuffer; emit 时机由 reorder buffer 决定, 保证 image / sample
    // 两条 delegate 通路按相同 (显示) 顺序出.
    CMSampleBufferRef out = NULL;
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &desc);
    if (s == noErr && desc) {
        // 解码出口重锚 PTS：把"流内 PTS"折回到 host time 域，basetime 锚定瞬间 = VT 出图瞬间，
        // 自然吃掉 VT 异步解码 / IDR 等待引入的偏置。无 anchor 时回退原 PTS（行为与改前一致）。
        CMTime remappedPts = presentationTimeStamp;
        id<TVUIRLDecodedPtsAnchor> anchor = decoder.ptsAnchor;
        if (anchor) {
            remappedPts = [anchor remapVideoDecodedPts:presentationTimeStamp];
        }
        CMSampleTimingInfo timing = {
            .duration = presentationDuration,
            .presentationTimeStamp = remappedPts,
            .decodeTimeStamp = kCMTimeInvalid,
        };
        s = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault, imageBuffer, true, NULL, NULL,
            desc, &timing, &out);
        CFRelease(desc);
    }

    if (sourceSample) CFRelease(sourceSample);

    if (out) {
        [decoder ingestSampleBuffer:out];
        CFRelease(out);
    }
}
