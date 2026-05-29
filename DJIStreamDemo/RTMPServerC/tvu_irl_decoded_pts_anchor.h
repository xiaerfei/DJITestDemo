/*
 * tvu_irl_decoded_pts_anchor.h
 *
 * 替代 TVUIRLDecodedPtsAnchor 协议。视频/音频解码器把"流内 PTS"折回到 host time
 * 域，吃掉异步解码 / IDR 等待的偏置。stream_connection 实现这一对函数。
 *
 * 函数指针 + void *user：线程安全由实现方保证（VT 回调线程 + RTMP socket 线程
 * 并发访问）。
 *
 * 返回 kCMTimeInvalid 表示该帧应被丢弃（例如 video basetime 未就绪时音频先到达）。
 */

#ifndef TVU_IRL_DECODED_PTS_ANCHOR_H
#define TVU_IRL_DECODED_PTS_ANCHOR_H

#include <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    CMTime (*remap_video_pts)(CMTime pts, void *user);   /* 可为 NULL */
    CMTime (*remap_audio_pts)(CMTime pts, void *user);   /* 可为 NULL */
    void *user;
} tvu_irl_decoded_pts_anchor_t;

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_DECODED_PTS_ANCHOR_H */
