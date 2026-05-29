/*
 * tvu_irl_hardware_decoder.c
 */

#include "tvu_irl_hardware_decoder.h"
#include "tvu_irl_log.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

#define REORDER_DEPTH_WHEN_BFRAMED 4

static void vt_output_callback(
    void *decompression_output_refcon,
    void *source_frame_refcon,
    OSStatus status,
    VTDecodeInfoFlags info_flags,
    CVImageBufferRef image_buffer,
    CMTime presentation_time_stamp,
    CMTime presentation_duration);

void tvu_irl_hardware_decoder_init(tvu_irl_hardware_decoder_t *d, dispatch_queue_t queue) {
    memset(d, 0, sizeof(*d));
    if (queue) {
        d->queue = queue;
        dispatch_retain(d->queue);
    }
    pthread_mutex_init(&d->reorder_lock, NULL);
    atomic_init(&d->reorder_depth, 0);
}

static void invalidate_session(tvu_irl_hardware_decoder_t *d) {
    if (d->session) {
        VTDecompressionSessionInvalidate(d->session);
        CFRelease(d->session);
        d->session = NULL;
    }
}

static void drain_reorder_buffer_locked(tvu_irl_hardware_decoder_t *d,
                                        CMSampleBufferRef *drained, int *out_count) {
    *out_count = d->reorder_count;
    for (int i = 0; i < d->reorder_count; i++) {
        drained[i] = d->reorder_buffer[i];
        d->reorder_buffer[i] = NULL;
    }
    d->reorder_count = 0;
}

static void emit_sample_buffer(tvu_irl_hardware_decoder_t *d, CMSampleBufferRef sb) {
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (img && d->callbacks.on_image_buffer) {
        d->callbacks.on_image_buffer(img, d->callbacks.user);
    }
    if (d->callbacks.on_sample_buffer) {
        d->callbacks.on_sample_buffer(sb, d->callbacks.user);
    }
}

static void drain_reorder_buffer(tvu_irl_hardware_decoder_t *d) {
    CMSampleBufferRef drained[TVU_IRL_HW_REORDER_CAP];
    int count;
    pthread_mutex_lock(&d->reorder_lock);
    drain_reorder_buffer_locked(d, drained, &count);
    pthread_mutex_unlock(&d->reorder_lock);
    for (int i = 0; i < count; i++) {
        emit_sample_buffer(d, drained[i]);
        CFRelease(drained[i]);
    }
}

void tvu_irl_hardware_decoder_destroy(tvu_irl_hardware_decoder_t *d) {
    tvu_irl_hardware_decoder_stop(d);
    pthread_mutex_destroy(&d->reorder_lock);
    if (d->queue) {
        dispatch_release(d->queue);
        d->queue = NULL;
    }
}

void tvu_irl_hardware_decoder_set_callbacks(tvu_irl_hardware_decoder_t *d,
                                            tvu_irl_hw_decoder_callbacks_t cb) {
    d->callbacks = cb;
}

void tvu_irl_hardware_decoder_set_anchor(tvu_irl_hardware_decoder_t *d,
                                         tvu_irl_decoded_pts_anchor_t anchor) {
    d->anchor = anchor;
    d->has_anchor = (anchor.remap_video_pts != NULL);
}

static bool create_session(tvu_irl_hardware_decoder_t *d) {
    if (!d->format_description) return false;
    /* NV12 (420v) 输出，匹配主工程相机直通格式 */
    const void *keys[3] = {
        kCVPixelBufferPixelFormatTypeKey,
        kCVPixelBufferIOSurfacePropertiesKey,
        kCVPixelBufferMetalCompatibilityKey,
    };
    int32_t pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pf = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixel_format);
    CFDictionaryRef iosurface_props = CFDictionaryCreate(
        kCFAllocatorDefault, NULL, NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *values[3] = { pf, iosurface_props, kCFBooleanTrue };
    CFDictionaryRef output_attrs = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(pf);
    CFRelease(iosurface_props);

    VTDecompressionOutputCallbackRecord cb = {
        .decompressionOutputCallback = vt_output_callback,
        .decompressionOutputRefCon   = d,
    };
    VTDecompressionSessionRef session = NULL;
    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault, d->format_description, NULL, output_attrs, &cb, &session);
    CFRelease(output_attrs);

    if (status != noErr || !session) {
        TVU_IRL_LOG_ERROR("rtmp-server: VTDecompressionSessionCreate failed: %d", (int)status);
        return false;
    }
    d->session = session;
    return true;
}

bool tvu_irl_hardware_decoder_start(tvu_irl_hardware_decoder_t *d,
                                    CMVideoFormatDescriptionRef format_description) {
    if (!format_description) return false;
    tvu_irl_hardware_decoder_stop(d);
    atomic_store(&d->reorder_depth, 0);
    d->format_description = (CMVideoFormatDescriptionRef)CFRetain(format_description);
    return create_session(d);
}

void tvu_irl_hardware_decoder_stop(tvu_irl_hardware_decoder_t *d) {
    if (d->session) {
        VTDecompressionSessionWaitForAsynchronousFrames(d->session);
    }
    drain_reorder_buffer(d);
    invalidate_session(d);
    if (d->format_description) {
        CFRelease(d->format_description);
        d->format_description = NULL;
    }
}

static OSStatus submit_frame(tvu_irl_hardware_decoder_t *d, CMSampleBufferRef sb) {
    if (!d->session) return kVTInvalidSessionErr;
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags info = 0;
    /* sb 引用计数：传给 VT 一份，回调中 CFRelease；调用 CFRetain 持有副本 */
    CMSampleBufferRef retained = (CMSampleBufferRef)CFRetain(sb);
    OSStatus status = VTDecompressionSessionDecodeFrame(d->session, sb, flags, retained, &info);
    if (status != noErr) CFRelease(retained);
    return status;
}

void tvu_irl_hardware_decoder_decode(tvu_irl_hardware_decoder_t *d,
                                     CMSampleBufferRef sample_buffer) {
    if (!sample_buffer || !d->session) return;
    /* 首次发现 PTS != DTS 即视为含 B 帧，开启 reorder buffer（一旦开启不再关闭） */
    if (atomic_load(&d->reorder_depth) == 0) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample_buffer);
        CMTime dts = CMSampleBufferGetDecodeTimeStamp(sample_buffer);
        if (CMTIME_IS_VALID(pts) && CMTIME_IS_VALID(dts) && CMTimeCompare(pts, dts) != 0) {
            atomic_store(&d->reorder_depth, REORDER_DEPTH_WHEN_BFRAMED);
            TVU_IRL_LOG("rtmp-server: PTS reorder buffer enabled (depth=%d)", REORDER_DEPTH_WHEN_BFRAMED);
        }
    }
    OSStatus status = submit_frame(d, sample_buffer);
    /* -12903 (kVTInvalidSessionErr)：app 进后台时 VT 资源被回收。重建会话再投一次。 */
    if (status == kVTInvalidSessionErr) {
        TVU_IRL_LOG("rtmp-server: VT session invalidated, recreating");
        invalidate_session(d);
        if (create_session(d)) {
            status = submit_frame(d, sample_buffer);
        }
    }
    if (status != noErr) {
        TVU_IRL_LOG_ERROR("rtmp-server: VTDecompressionSessionDecodeFrame failed: %d", (int)status);
    }
}

/* 把已重锚 PTS 的 sample buffer 插入 reorder buffer，必要时弹出最小 PTS 一帧。 */
static void ingest_into_reorder(tvu_irl_hardware_decoder_t *d, CMSampleBufferRef sb) {
    int depth = atomic_load(&d->reorder_depth);
    if (depth == 0) {
        emit_sample_buffer(d, sb);
        return;
    }
    CMSampleBufferRef to_emit = NULL;

    pthread_mutex_lock(&d->reorder_lock);
    CMTime sb_pts = CMSampleBufferGetPresentationTimeStamp(sb);
    int insert_at = d->reorder_count;
    for (int i = 0; i < d->reorder_count; i++) {
        CMTime existing = CMSampleBufferGetPresentationTimeStamp(d->reorder_buffer[i]);
        if (CMTimeCompare(sb_pts, existing) < 0) { insert_at = i; break; }
    }
    /* 容量保护：溢出时强制弹出最小 PTS 那帧 */
    if (d->reorder_count >= TVU_IRL_HW_REORDER_CAP) {
        to_emit = d->reorder_buffer[0];
        for (int i = 1; i < d->reorder_count; i++) d->reorder_buffer[i - 1] = d->reorder_buffer[i];
        d->reorder_count--;
        if (insert_at > 0) insert_at--;
    }
    for (int i = d->reorder_count; i > insert_at; i--) d->reorder_buffer[i] = d->reorder_buffer[i - 1];
    CFRetain(sb);
    d->reorder_buffer[insert_at] = sb;
    d->reorder_count++;
    if (!to_emit && d->reorder_count > depth) {
        to_emit = d->reorder_buffer[0];
        for (int i = 1; i < d->reorder_count; i++) d->reorder_buffer[i - 1] = d->reorder_buffer[i];
        d->reorder_count--;
    }
    pthread_mutex_unlock(&d->reorder_lock);

    if (to_emit) {
        emit_sample_buffer(d, to_emit);
        CFRelease(to_emit);
    }
}

static void vt_output_callback(
    void *decompression_output_refcon,
    void *source_frame_refcon,
    OSStatus status,
    VTDecodeInfoFlags info_flags,
    CVImageBufferRef image_buffer,
    CMTime presentation_time_stamp,
    CMTime presentation_duration)
{
    (void)info_flags;
    tvu_irl_hardware_decoder_t *d = (tvu_irl_hardware_decoder_t *)decompression_output_refcon;
    CMSampleBufferRef source_sample = (CMSampleBufferRef)source_frame_refcon;

    if (status != noErr || !image_buffer) {
        if (source_sample) CFRelease(source_sample);
        return;
    }

    /* 构建出口 sample buffer（含重锚后的 PTS），送进 reorder buffer。 */
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image_buffer, &desc);
    CMSampleBufferRef out = NULL;
    if (s == noErr && desc) {
        CMTime remapped = presentation_time_stamp;
        if (d->has_anchor && d->anchor.remap_video_pts) {
            remapped = d->anchor.remap_video_pts(presentation_time_stamp, d->anchor.user);
        }
        CMSampleTimingInfo timing = {
            .duration              = presentation_duration,
            .presentationTimeStamp = remapped,
            .decodeTimeStamp       = kCMTimeInvalid,
        };
        s = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault, image_buffer, true, NULL, NULL, desc, &timing, &out);
        CFRelease(desc);
    }
    if (source_sample) CFRelease(source_sample);
    if (out) {
        ingest_into_reorder(d, out);
        CFRelease(out);
    }
}
