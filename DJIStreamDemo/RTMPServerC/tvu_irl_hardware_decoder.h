/*
 * tvu_irl_hardware_decoder.h
 *
 * 替代 TVUIRLHardwareDecoder。VideoToolbox VTDecompressionSession 包装，
 * 出口 PTS reorder buffer。
 *
 * 线程模型：
 *   - decode_sample_buffer 在 caller queue 调用
 *   - VT 回调在 VT 内部线程；通过 pthread_mutex 保护 reorder buffer
 *   - on_sample_buffer / on_image_buffer 回调在 VT 线程触发（与原 ObjC 行为一致）
 *
 * 内存模型：
 *   - format_description CFRetain，stop / destroy 时 CFRelease
 *   - session CFRelease 时随之销毁
 *   - reorder buffer 持有 CMSampleBufferRef 的 retain；drain 时 CFRelease 全部
 */

#ifndef TVU_IRL_HARDWARE_DECODER_H
#define TVU_IRL_HARDWARE_DECODER_H

#include "tvu_irl_decoded_pts_anchor.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TVU_IRL_HW_REORDER_CAP 8

typedef struct {
    void (*on_sample_buffer)(CMSampleBufferRef sb, void *user);   /* nullable */
    void (*on_image_buffer)(CVImageBufferRef ib, void *user);     /* nullable */
    void *user;
} tvu_irl_hw_decoder_callbacks_t;

typedef struct {
    dispatch_queue_t                queue;             /* retained */
    VTDecompressionSessionRef       session;           /* 持有；session != NULL 表示 ready */
    CMVideoFormatDescriptionRef     format_description;/* CFRetain */

    /* reorder buffer：固定大小数组，互斥保护。
     * depth=0：直通；depth>0：等候 depth+1 帧后弹出最小 PTS 那帧。 */
    pthread_mutex_t                 reorder_lock;
    CMSampleBufferRef               reorder_buffer[TVU_IRL_HW_REORDER_CAP];
    int                             reorder_count;
    _Atomic int                     reorder_depth;

    /* 回调 & anchor */
    tvu_irl_hw_decoder_callbacks_t  callbacks;
    tvu_irl_decoded_pts_anchor_t    anchor;
    bool                            has_anchor;
} tvu_irl_hardware_decoder_t;

void tvu_irl_hardware_decoder_init(tvu_irl_hardware_decoder_t *d, dispatch_queue_t queue);
void tvu_irl_hardware_decoder_destroy(tvu_irl_hardware_decoder_t *d);

void tvu_irl_hardware_decoder_set_callbacks(tvu_irl_hardware_decoder_t *d,
                                            tvu_irl_hw_decoder_callbacks_t cb);
void tvu_irl_hardware_decoder_set_anchor(tvu_irl_hardware_decoder_t *d,
                                         tvu_irl_decoded_pts_anchor_t anchor);

bool tvu_irl_hardware_decoder_start(tvu_irl_hardware_decoder_t *d,
                                    CMVideoFormatDescriptionRef format_description);
void tvu_irl_hardware_decoder_stop(tvu_irl_hardware_decoder_t *d);

void tvu_irl_hardware_decoder_decode(tvu_irl_hardware_decoder_t *d,
                                     CMSampleBufferRef sample_buffer);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_HARDWARE_DECODER_H */
