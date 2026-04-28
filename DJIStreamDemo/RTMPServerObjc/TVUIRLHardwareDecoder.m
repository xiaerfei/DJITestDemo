//
//  TVUIRLHardwareDecoder.m
//  DJIStreamDemo
//

#import "TVUIRLHardwareDecoder.h"
#import <VideoToolbox/VideoToolbox.h>

@interface TVUIRLHardwareDecoder ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) VTDecompressionSessionRef session;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDescription;
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
    self.formatDescription = (CMVideoFormatDescriptionRef)CFRetain(formatDescription);

    NSDictionary *outputAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
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
        formatDescription,
        NULL,
        (__bridge CFDictionaryRef)outputAttrs,
        &cb,
        &session);
    if (status != noErr || !session) {
        NSLog(@"rtmp-server: VTDecompressionSessionCreate failed: %d", (int)status);
        return NO;
    }
    self.session = session;
    return YES;
}

- (void)stop {
    if (self.session) {
        VTDecompressionSessionWaitForAsynchronousFrames(self.session);
        VTDecompressionSessionInvalidate(self.session);
        CFRelease(self.session);
        self.session = NULL;
    }
    if (self.formatDescription) {
        CFRelease(self.formatDescription);
        self.formatDescription = NULL;
    }
}

- (void)decodeSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.session || !sampleBuffer) return;
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
        NSLog(@"rtmp-server: VTDecompressionSessionDecodeFrame failed: %d", (int)status);
        CFRelease(retained);
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

    id<TVUIRLHardwareDecoderDelegate> delegate = decoder.delegate;
    if ([delegate respondsToSelector:@selector(hardwareDecoder:didDecodeImageBuffer:)]) {
        [delegate hardwareDecoder:decoder didDecodeImageBuffer:imageBuffer];
    }

    if ([delegate respondsToSelector:@selector(hardwareDecoder:didDecodeSampleBuffer:)]) {
        CMVideoFormatDescriptionRef desc = NULL;
        OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &desc);
        if (s == noErr && desc) {
            CMSampleTimingInfo timing = {
                .duration = presentationDuration,
                .presentationTimeStamp = presentationTimeStamp,
                .decodeTimeStamp = kCMTimeInvalid,
            };
            CMSampleBufferRef out = NULL;
            s = CMSampleBufferCreateForImageBuffer(
                kCFAllocatorDefault, imageBuffer, true, NULL, NULL,
                desc, &timing, &out);
            if (s == noErr && out) {
                [delegate hardwareDecoder:decoder didDecodeSampleBuffer:out];
                CFRelease(out);
            }
            CFRelease(desc);
        }
    }
    if (sourceSample) CFRelease(sourceSample);
}
