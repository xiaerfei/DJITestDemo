/*
 * tvu_irl_stream_connection.h
 *
 * 替代 TVUIRLStreamConnection。单 RTMP 客户端连接：握手 + chunk 状态机
 * + ring buffer + overflow B + PLL 解码出口 PTS 锚。
 *
 * 内部持有：transport 引用 + 64 个 pipeline slot + bandwidth_meter 转发 +
 * 调用 server 接口（前向声明）通报生命周期事件 / 转发 sample buffer。
 */

#ifndef TVU_IRL_STREAM_CONNECTION_H
#define TVU_IRL_STREAM_CONNECTION_H

#include "tvu_irl_str.h"
#include "tvu_irl_transport.h"
#include "tvu_irl_decoded_pts_anchor.h"
#include "tvu_irl_media_clock.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <uuid/uuid.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 服务器前向声明。phase 7 提供定义和 server 接口函数实现。 */
typedef struct tvu_irl_streaming_server tvu_irl_streaming_server_t;

typedef enum {
    TVU_IRL_LIFECYCLE_IDLE,
    TVU_IRL_LIFECYCLE_CONNECTING,
    TVU_IRL_LIFECYCLE_CONNECTED,
} tvu_irl_lifecycle_t;

typedef struct tvu_irl_media_pipeline tvu_irl_media_pipeline_t;
typedef struct tvu_irl_stream_connection tvu_irl_stream_connection_t;

/* 创建连接。take ownership of transport（destroy 时 cancel + destroy transport）。 */
tvu_irl_stream_connection_t *tvu_irl_stream_connection_create(
    tvu_irl_streaming_server_t *server,
    tvu_irl_connection_t       *transport);

void tvu_irl_stream_connection_destroy(tvu_irl_stream_connection_t *c);

void tvu_irl_stream_connection_start(tvu_irl_stream_connection_t *c);
void tvu_irl_stream_connection_stop(tvu_irl_stream_connection_t *c, const char *reason);

/* 发送已编码好的字节（caller 保证 RTMP chunk 结构正确）。 */
void tvu_irl_stream_connection_send_bytes(tvu_irl_stream_connection_t *c,
                                          const void *data, size_t length);

/* ============================== Pipeline → Connection 回调 ============================== */

void tvu_irl_stream_connection_pipeline_produced_video_sample(
    tvu_irl_stream_connection_t *c, CMSampleBufferRef sb);
void tvu_irl_stream_connection_pipeline_produced_video_image(
    tvu_irl_stream_connection_t *c, CVImageBufferRef ib);
void tvu_irl_stream_connection_pipeline_produced_audio_sample(
    tvu_irl_stream_connection_t *c, CMSampleBufferRef sb);
void tvu_irl_stream_connection_pipeline_observed_video_pts(
    tvu_irl_stream_connection_t *c, double pts);
void tvu_irl_stream_connection_pipeline_observed_audio_pts(
    tvu_irl_stream_connection_t *c, double pts);

/* 视频首帧时建立的 host time 锚点（毫秒）。 */
double tvu_irl_stream_connection_base_pts_ms(tvu_irl_stream_connection_t *c);

/* ============================== 字段访问 ============================== */

tvu_irl_streaming_server_t *tvu_irl_stream_connection_server(tvu_irl_stream_connection_t *c);
const char *tvu_irl_stream_connection_stream_key(const tvu_irl_stream_connection_t *c);
int32_t     tvu_irl_stream_connection_latency_ms(const tvu_irl_stream_connection_t *c);
double      tvu_irl_stream_connection_last_video_rtmp_ts(const tvu_irl_stream_connection_t *c);
void        tvu_irl_stream_connection_set_last_video_rtmp_ts(tvu_irl_stream_connection_t *c, double ts);
const uint8_t *tvu_irl_stream_connection_camera_id(const tvu_irl_stream_connection_t *c);
CFAbsoluteTime tvu_irl_stream_connection_latest_receive_time(const tvu_irl_stream_connection_t *c);
tvu_irl_lifecycle_t tvu_irl_stream_connection_lifecycle(const tvu_irl_stream_connection_t *c);

/* 暴露给 pipeline 写入：chunk_size_from_client / chunk_size_to_client /
 * window_ack_size，以及 publish 命中后设置 stream_key / camera_id / latency /
 * lifecycle。设计成 friend 函数避免暴露完整 struct。 */
int32_t  tvu_irl_stream_connection_chunk_size_from_client(const tvu_irl_stream_connection_t *c);
int32_t  tvu_irl_stream_connection_chunk_size_to_client(const tvu_irl_stream_connection_t *c);
void     tvu_irl_stream_connection_set_chunk_size_from_client(tvu_irl_stream_connection_t *c, int32_t v);
void     tvu_irl_stream_connection_set_chunk_size_to_client(tvu_irl_stream_connection_t *c, int32_t v);
void     tvu_irl_stream_connection_set_window_ack_size(tvu_irl_stream_connection_t *c, int32_t v);
void     tvu_irl_stream_connection_complete_publish(tvu_irl_stream_connection_t *c,
                                                    const char *stream_key,
                                                    int32_t latency_ms,
                                                    const uint8_t uuid[16]);

/* 返回 PTS anchor，用于注入到 hardware/audio decoder。 */
tvu_irl_decoded_pts_anchor_t tvu_irl_stream_connection_pts_anchor(tvu_irl_stream_connection_t *c);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_STREAM_CONNECTION_H */
