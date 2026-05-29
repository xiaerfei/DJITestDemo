/*
 * tvu_irl_streaming_server.h
 *
 * RTMP Streaming Server 对外 C API + 内部连接/pipeline 调用接口。
 *
 * Phase 7 提供完整公开 API；Phase 6 先用其中的内部转发函数。
 */

#ifndef TVU_IRL_STREAMING_SERVER_H
#define TVU_IRL_STREAMING_SERVER_H

#include "tvu_irl_stream_config.h"
#include "tvu_irl_bandwidth_meter.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tvu_irl_streaming_server tvu_irl_streaming_server_t;
typedef struct tvu_irl_stream_connection tvu_irl_stream_connection_t;

/* ============================== 对外 C 回调表 ============================== */

typedef struct {
    /* publish 开始 / 停止。reason 是 const char *。 */
    void (*on_publish_start)(const char *stream_key, void *user);
    void (*on_publish_stop)(const char *stream_key, const char *reason, void *user);
    /* 视频 / 音频 sample buffer。回调期间持有；caller 必须 CFRetain 才能持有更久。 */
    void (*on_video_sample_buffer)(CMSampleBufferRef sb, void *user);
    void (*on_video_image_buffer)(CVImageBufferRef ib, void *user);
    void (*on_audio_sample_buffer)(CMSampleBufferRef sb, void *user);
    /* 统计快照（含瞬时码率）。 */
    void (*on_stats_update)(tvu_irl_bandwidth_snapshot_t snapshot, void *user);
    /* 音视频目标延迟更新（同步决策结果）。 */
    void (*on_target_latencies)(double video_latency, double audio_latency, void *user);
    void *user;
} tvu_irl_server_callbacks_t;

/* ============================== 对外 API ============================== */

/* 创建 server。config 内部深拷贝。callbacks 复制一份。 */
tvu_irl_streaming_server_t *tvu_irl_streaming_server_create(
    const tvu_irl_stream_config_t *config,
    tvu_irl_server_callbacks_t callbacks);

void tvu_irl_streaming_server_destroy(tvu_irl_streaming_server_t *s);

bool tvu_irl_streaming_server_start(tvu_irl_streaming_server_t *s);
void tvu_irl_streaming_server_stop(tvu_irl_streaming_server_t *s);

bool   tvu_irl_streaming_server_is_stream_connected(const tvu_irl_streaming_server_t *s,
                                                    const char *stream_key);
size_t tvu_irl_streaming_server_num_clients(const tvu_irl_streaming_server_t *s);
tvu_irl_bandwidth_snapshot_t tvu_irl_streaming_server_update_stats(tvu_irl_streaming_server_t *s);

/* ============================== 内部接口（由 connection / pipeline 调用） ============================== */

dispatch_queue_t                tvu_irl_streaming_server_queue(tvu_irl_streaming_server_t *s);
const tvu_irl_stream_config_t  *tvu_irl_streaming_server_config(tvu_irl_streaming_server_t *s);

void tvu_irl_streaming_server_connection_did_complete(
    tvu_irl_streaming_server_t *s, tvu_irl_stream_connection_t *c);
void tvu_irl_streaming_server_connection_did_disconnect(
    tvu_irl_streaming_server_t *s, tvu_irl_stream_connection_t *c, const char *reason);

void tvu_irl_streaming_server_forward_video_sample(
    tvu_irl_streaming_server_t *s, CMSampleBufferRef sb);
void tvu_irl_streaming_server_forward_video_image(
    tvu_irl_streaming_server_t *s, CVImageBufferRef ib);
void tvu_irl_streaming_server_forward_audio_sample(
    tvu_irl_streaming_server_t *s, CMSampleBufferRef sb);
void tvu_irl_streaming_server_forward_target_latencies(
    tvu_irl_streaming_server_t *s, double video, double audio);

void tvu_irl_streaming_server_bandwidth_add(
    tvu_irl_streaming_server_t *s, size_t bytes);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_STREAMING_SERVER_H */
