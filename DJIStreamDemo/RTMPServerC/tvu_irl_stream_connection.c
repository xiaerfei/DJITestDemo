/*
 * tvu_irl_stream_connection.c
 *
 * 单 RTMP 客户端连接：
 *   - 8MB ring buffer + 旁路 overflow B（替代 NSMutableData，Plan 10）
 *   - 内联 chunk 状态机（Plan 8）
 *   - 64 个 chunk_stream_id pipeline slot（替代 NSDictionary 查找）
 *   - PLL 解码出口 PTS 锚（basetime 慢牵 + audio 跟随）
 *
 * 删去原 ObjC 版中大量逐帧诊断日志（Layer-1/Layer-2 DJI trace）以保持代码紧凑；
 * 错误日志与关键状态转换保留。
 */

#include "tvu_irl_stream_connection.h"
#include "tvu_irl_media_pipeline.h"
#include "tvu_irl_streaming_server.h"
#include "tvu_irl_messages.h"
#include "tvu_irl_media_packet.h"
#include "tvu_irl_log.h"

#include <QuartzCore/QuartzCore.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#define RTMP_VERSION 3

#define RING_CAPACITY      (8 * 1024 * 1024)
#define OVERFLOW_INIT_CAP  (256 * 1024)
#define OVERFLOW_MAX_CAP   (4 * 1024 * 1024)

/* ============================== 内部类型 ============================== */

typedef struct {
    uint8_t *base;
    int64_t  capacity;
    int64_t  read_idx;
    int64_t  write_idx;
    int64_t  used;
    int64_t  valid_end;
} ring_buffer_t;

typedef struct {
    uint8_t *buf;
    int64_t  capacity;
    int64_t  len;
} overflow_buf_t;

typedef enum {
    HS_UNINITIALIZED,
    HS_VERSION_SENT,
    HS_ACK_SENT,
    HS_DONE,
} hs_state_t;

typedef enum {
    CHUNK_BASIC_HEADER_FIRST_BYTE,
    CHUNK_MSG_HEADER_TYPE0,
    CHUNK_MSG_HEADER_TYPE1,
    CHUNK_MSG_HEADER_TYPE2,
    CHUNK_EXTENDED_TIMESTAMP,
    CHUNK_DATA,
} chunk_parser_state_t;

struct tvu_irl_stream_connection {
    tvu_irl_streaming_server_t *server;
    tvu_irl_connection_t       *transport;

    hs_state_t           hs_state;
    chunk_parser_state_t chunk_state;
    int64_t              receive_size;
    uint64_t             total_bytes_received;
    uint64_t             total_bytes_received_acked;

    ring_buffer_t        ring;
    overflow_buf_t       overflow;

    tvu_irl_media_pipeline_t *pipeline_slots[64];
    tvu_irl_media_pipeline_t *current_pipeline;

    tvu_irl_str_t        stream_key;
    int32_t              latency_ms;
    uuid_t               camera_id;
    int32_t              chunk_size_from_client;
    int32_t              chunk_size_to_client;
    int32_t              window_ack_size;
    _Atomic int          lifecycle;
    CFAbsoluteTime       latest_receive_abs_time;
    _Atomic double       last_video_rtmp_ts;
    bool                 receive_batch_mode_enabled;

    tvu_irl_media_clock_t media_clock;
    double                base_pts_ms_value;
    bool                  has_base_pts;

    /* PLL anchor 状态：受 anchor_lock 保护 */
    os_unfair_lock anchor_lock;
    bool   anchor_basetime_ready;
    CMTime anchor_basetime;
    bool   video_first_pts_ready;
    CMTime video_first_pts;
    bool   audio_first_pts_ready;
    CMTime audio_first_pts;
    CMTime last_audio_new_pts;     /* 防御性 clamp */
    double filtered_drift_ms;
};

/* ============================== Ring buffer 操作 ============================== */

static bool overflow_append(tvu_irl_stream_connection_t *c, const void *bytes, int64_t length);
static void ring_drain_overflow(tvu_irl_stream_connection_t *c);

static bool ring_write_bytes(tvu_irl_stream_connection_t *c, const void *bytes, int64_t length) {
    if (length <= 0) return true;
    if (c->overflow.len > 0) {
        if (!overflow_append(c, bytes, length)) return false;
        ring_drain_overflow(c);
        return true;
    }
    if (c->ring.used == 0) {
        c->ring.write_idx = 0; c->ring.read_idx = 0; c->ring.valid_end = c->ring.capacity;
    }
    int64_t remaining = c->ring.capacity - c->ring.used;
    if (length > remaining) return overflow_append(c, bytes, length);

    int64_t contig;
    if (c->ring.used == 0) contig = c->ring.capacity;
    else if (c->ring.write_idx >= c->ring.read_idx) contig = c->ring.capacity - c->ring.write_idx;
    else contig = c->ring.read_idx - c->ring.write_idx;

    if (length <= contig) {
        memcpy(c->ring.base + c->ring.write_idx, bytes, (size_t)length);
        c->ring.write_idx += length;
        if (c->ring.write_idx == c->ring.capacity) c->ring.write_idx = 0;
        c->ring.used += length;
        return true;
    }
    /* 路径 (b)：未 wrap，强制 wrap writeIdx 回 0 */
    if (c->ring.write_idx > c->ring.read_idx && c->ring.read_idx >= length) {
        c->ring.valid_end = c->ring.write_idx;
        memcpy(c->ring.base, bytes, (size_t)length);
        c->ring.write_idx = length;
        c->ring.used += length;
        return true;
    }
    return overflow_append(c, bytes, length);
}

static bool ring_read_advance(tvu_irl_stream_connection_t *c, uint8_t *dest, int64_t length) {
    if (length <= 0) return true;
    if (c->ring.used < length) return false;
    bool is_wrapped = (c->ring.write_idx < c->ring.read_idx) ||
                      (c->ring.write_idx == c->ring.read_idx && c->ring.used == c->ring.capacity);
    int64_t tail_len = is_wrapped
        ? (c->ring.valid_end - c->ring.read_idx)
        : (c->ring.write_idx - c->ring.read_idx);

    if (length <= tail_len) {
        memcpy(dest, c->ring.base + c->ring.read_idx, (size_t)length);
        c->ring.read_idx += length;
        if (is_wrapped && c->ring.read_idx >= c->ring.valid_end) {
            c->ring.read_idx = 0;
            c->ring.valid_end = c->ring.capacity;
        }
    } else {
        memcpy(dest, c->ring.base + c->ring.read_idx, (size_t)tail_len);
        int64_t head_take = length - tail_len;
        memcpy(dest + tail_len, c->ring.base, (size_t)head_take);
        c->ring.read_idx = head_take;
        c->ring.valid_end = c->ring.capacity;
    }
    c->ring.used -= length;
    if (c->overflow.len > 0) ring_drain_overflow(c);
    return true;
}

static bool ring_consume_to_pipeline(tvu_irl_stream_connection_t *c,
                                     int64_t length,
                                     tvu_irl_media_pipeline_t *pipeline) {
    if (length <= 0) return true;
    if (c->ring.used < length) return false;
    bool is_wrapped = (c->ring.write_idx < c->ring.read_idx) ||
                      (c->ring.write_idx == c->ring.read_idx && c->ring.used == c->ring.capacity);
    int64_t tail_len = is_wrapped
        ? (c->ring.valid_end - c->ring.read_idx)
        : (c->ring.write_idx - c->ring.read_idx);

    if (length <= tail_len) {
        tvu_irl_media_pipeline_append_chunk_bytes(pipeline, c->ring.base + c->ring.read_idx, (size_t)length);
        c->ring.read_idx += length;
        if (is_wrapped && c->ring.read_idx >= c->ring.valid_end) {
            c->ring.read_idx = 0;
            c->ring.valid_end = c->ring.capacity;
        }
    } else {
        tvu_irl_media_pipeline_append_chunk_bytes(pipeline, c->ring.base + c->ring.read_idx, (size_t)tail_len);
        int64_t head_take = length - tail_len;
        tvu_irl_media_pipeline_append_chunk_bytes(pipeline, c->ring.base, (size_t)head_take);
        c->ring.read_idx = head_take;
        c->ring.valid_end = c->ring.capacity;
    }
    c->ring.used -= length;
    if (c->overflow.len > 0) ring_drain_overflow(c);
    return true;
}

static bool overflow_append(tvu_irl_stream_connection_t *c, const void *bytes, int64_t length) {
    if (length <= 0) return true;
    int64_t need = c->overflow.len + length;
    if (need > OVERFLOW_MAX_CAP) return false;
    if (need > c->overflow.capacity) {
        int64_t new_cap = c->overflow.capacity ? c->overflow.capacity : OVERFLOW_INIT_CAP;
        while (new_cap < need) new_cap *= 2;
        if (new_cap > OVERFLOW_MAX_CAP) new_cap = OVERFLOW_MAX_CAP;
        uint8_t *nb = (uint8_t *)realloc(c->overflow.buf, (size_t)new_cap);
        if (!nb) return false;
        c->overflow.buf = nb;
        c->overflow.capacity = new_cap;
    }
    memcpy(c->overflow.buf + c->overflow.len, bytes, (size_t)length);
    c->overflow.len += length;
    return true;
}

static void ring_drain_overflow(tvu_irl_stream_connection_t *c) {
    while (c->overflow.len > 0) {
        int64_t remaining = c->ring.capacity - c->ring.used;
        if (remaining == 0) return;
        if (c->ring.used == 0) {
            c->ring.write_idx = 0; c->ring.read_idx = 0; c->ring.valid_end = c->ring.capacity;
        }
        int64_t contig;
        if (c->ring.used == 0) contig = c->ring.capacity;
        else if (c->ring.write_idx >= c->ring.read_idx) contig = c->ring.capacity - c->ring.write_idx;
        else contig = c->ring.read_idx - c->ring.write_idx;
        if (contig == 0) {
            if (c->ring.write_idx > c->ring.read_idx && c->ring.read_idx > 0) {
                c->ring.valid_end = c->ring.write_idx;
                c->ring.write_idx = 0;
                continue;
            }
            return;
        }
        int64_t n = c->overflow.len;
        if (n > contig) n = contig;
        if (n > remaining) n = remaining;
        memcpy(c->ring.base + c->ring.write_idx, c->overflow.buf, (size_t)n);
        c->ring.write_idx += n;
        if (c->ring.write_idx == c->ring.capacity) c->ring.write_idx = 0;
        c->ring.used += n;
        c->overflow.len -= n;
        if (c->overflow.len > 0) {
            memmove(c->overflow.buf, c->overflow.buf + n, (size_t)c->overflow.len);
        }
    }
}

/* ============================== 创建 / 销毁 ============================== */

tvu_irl_stream_connection_t *tvu_irl_stream_connection_create(
    tvu_irl_streaming_server_t *server,
    tvu_irl_connection_t       *transport) {
    tvu_irl_stream_connection_t *c = (tvu_irl_stream_connection_t *)calloc(1, sizeof(*c));
    if (!c) abort();
    c->server = server;
    c->transport = transport;
    c->hs_state = HS_UNINITIALIZED;
    c->chunk_state = CHUNK_BASIC_HEADER_FIRST_BYTE;
    c->ring.base = (uint8_t *)malloc(RING_CAPACITY);
    if (!c->ring.base) abort();
    c->ring.capacity = RING_CAPACITY;
    c->ring.valid_end = RING_CAPACITY;
    c->receive_size = 1 + 1536;
    c->latency_ms = 2000;
    uuid_generate_random(c->camera_id);
    c->chunk_size_from_client = 128;
    c->chunk_size_to_client = 128;
    c->window_ack_size = 2500000;
    c->latest_receive_abs_time = CFAbsoluteTimeGetCurrent();
    atomic_init(&c->lifecycle, TVU_IRL_LIFECYCLE_IDLE);
    atomic_init(&c->last_video_rtmp_ts, 0.0);
    tvu_irl_str_init(&c->stream_key);
    tvu_irl_media_clock_init(&c->media_clock, 2.0);
    c->anchor_lock = OS_UNFAIR_LOCK_INIT;
    c->anchor_basetime = kCMTimeInvalid;
    c->video_first_pts = kCMTimeInvalid;
    c->audio_first_pts = kCMTimeInvalid;
    c->last_audio_new_pts = kCMTimeInvalid;
    return c;
}

void tvu_irl_stream_connection_destroy(tvu_irl_stream_connection_t *c) {
    if (!c) return;
    /* 停止 pipeline 解码器，释放 CMSampleBufferRef 队列 */
    for (int i = 0; i < 64; i++) {
        if (c->pipeline_slots[i]) {
            tvu_irl_media_pipeline_destroy(c->pipeline_slots[i]);
            c->pipeline_slots[i] = NULL;
        }
    }
    if (c->transport) {
        tvu_irl_connection_destroy(c->transport);
        c->transport = NULL;
    }
    free(c->ring.base);
    free(c->overflow.buf);
    tvu_irl_str_destroy(&c->stream_key);
    free(c);
}

static void reset_anchor(tvu_irl_stream_connection_t *c) {
    os_unfair_lock_lock(&c->anchor_lock);
    c->anchor_basetime_ready = false;
    c->anchor_basetime = kCMTimeInvalid;
    c->video_first_pts_ready = false;
    c->video_first_pts = kCMTimeInvalid;
    c->audio_first_pts_ready = false;
    c->audio_first_pts = kCMTimeInvalid;
    c->last_audio_new_pts = kCMTimeInvalid;
    c->filtered_drift_ms = 0.0;
    os_unfair_lock_unlock(&c->anchor_lock);
}

void tvu_irl_stream_connection_stop(tvu_irl_stream_connection_t *c, const char *reason) {
    if (!c) return;
    TVU_IRL_LOG("rtmp-server: client stopping: %s", reason ? reason : "(no reason)");
    for (int i = 0; i < 64; i++) {
        if (c->pipeline_slots[i]) {
            tvu_irl_media_pipeline_stop(c->pipeline_slots[i]);
        }
    }
    if (c->transport) tvu_irl_connection_cancel(c->transport);
    atomic_store(&c->lifecycle, TVU_IRL_LIFECYCLE_IDLE);
    reset_anchor(c);
}

/* 内部触发：失败 / 错误退路。通知 server 然后停止。 */
static void stop_internal(tvu_irl_stream_connection_t *c, const char *reason) {
    if (atomic_load(&c->lifecycle) == TVU_IRL_LIFECYCLE_IDLE) return;
    tvu_irl_streaming_server_connection_did_disconnect(c->server, c, reason);
}

/* ============================== Send ============================== */

void tvu_irl_stream_connection_send_bytes(tvu_irl_stream_connection_t *c,
                                          const void *data, size_t length) {
    if (!c || !c->transport || length == 0) return;
    tvu_irl_connection_write(c->transport, data, length);
}

static void send_ack(tvu_irl_stream_connection_t *c) {
    tvu_irl_ack_message_t m;
    tvu_irl_ack_init_with_sequence(&m, (uint32_t)(c->total_bytes_received & 0xFFFFFFFFu));
    tvu_irl_bytes_t body; tvu_irl_bytes_init(&body);
    tvu_irl_ack_build_encoded(&m, &body);
    tvu_irl_bytes_t out; tvu_irl_bytes_init(&out);
    tvu_irl_media_packet_emit(TVU_IRL_PACKET_TYPE_ZERO, TVU_IRL_CSID_CONTROL,
                              TVU_IRL_MSG_ACK, 0, 0,
                              body.data, body.length, (size_t)c->chunk_size_to_client, &out);
    tvu_irl_stream_connection_send_bytes(c, out.data, out.length);
    tvu_irl_bytes_destroy(&out);
    tvu_irl_bytes_destroy(&body);
}

/* ============================== Handshake ============================== */

static void handshake_c0c1(tvu_irl_stream_connection_t *c, const uint8_t *data, int64_t length) {
    if (length != 1 + 1536) {
        char buf[64];
        snprintf(buf, sizeof(buf), "Wrong length %lld in uninitialized", (long long)length);
        stop_internal(c, buf);
        return;
    }
    if (data[0] != RTMP_VERSION) {
        stop_internal(c, "Only RTMP version 3 supported");
        return;
    }
    /* S0 */
    uint8_t s0 = RTMP_VERSION;
    tvu_irl_stream_connection_send_bytes(c, &s0, 1);
    /* S1: 8 zeros + 1528 random */
    uint8_t s1[1536];
    memset(s1, 0, 8);
    arc4random_buf(s1 + 8, 1528);
    tvu_irl_stream_connection_send_bytes(c, s1, 1536);
    c->hs_state = HS_VERSION_SENT;
    /* S2: C1[0..3] + zeros(4) + C1[8..1535] */
    uint8_t s2[1536];
    memcpy(s2, data + 1, 4);
    memset(s2 + 4, 0, 4);
    memcpy(s2 + 8, data + 9, 1528);
    tvu_irl_stream_connection_send_bytes(c, s2, 1536);
    c->hs_state = HS_ACK_SENT;
}

static void handshake_c2_done(tvu_irl_stream_connection_t *c) {
    c->hs_state = HS_DONE;
    c->chunk_state = CHUNK_BASIC_HEADER_FIRST_BYTE;
}

/* ============================== Receive Batch Mode ============================== */

static void maybe_enable_receive_batch_mode(tvu_irl_stream_connection_t *c) {
    if (c->receive_batch_mode_enabled) return;
    if (!c->current_pipeline) return;
    if (tvu_irl_media_pipeline_message_type_id(c->current_pipeline) != TVU_IRL_MSG_VIDEO) return;
    if (tvu_irl_media_pipeline_message_length(c->current_pipeline) <= 1024) return;
    c->receive_batch_mode_enabled = true;
    tvu_irl_connection_set_receive_batch_min_bytes(c->transport, 8192);
    TVU_IRL_LOG("[nw_recv] entering batch mode (min_byte=8192) after first real video frame");
}

/* ============================== Chunk parsing 主循环 ============================== */

static void process_received(tvu_irl_stream_connection_t *c,
                             const uint8_t *data, size_t length) {
    c->total_bytes_received += length;
    tvu_irl_streaming_server_bandwidth_add(c->server, length);
    c->latest_receive_abs_time = CFAbsoluteTimeGetCurrent();

    ring_drain_overflow(c);
    if (!ring_write_bytes(c, data, (int64_t)length)) {
        stop_internal(c, "Ring overflow");
        return;
    }

    /* 握手冷路径 */
    while (c->hs_state != HS_DONE) {
        int64_t hs_size;
        if (c->hs_state == HS_UNINITIALIZED)      hs_size = 1 + 1536;
        else if (c->hs_state == HS_ACK_SENT)      hs_size = 1536;
        else goto done;
        uint8_t hs_buf[1537];
        if (!ring_read_advance(c, hs_buf, hs_size)) goto done;
        if (c->hs_state == HS_UNINITIALIZED) {
            handshake_c0c1(c, hs_buf, hs_size);
        } else {
            handshake_c2_done(c);
        }
    }

    /* RTMP chunk 解析热路径 */
    while (c->ring.used > 0) {
        switch (c->chunk_state) {
            case CHUNK_BASIC_HEADER_FIRST_BYTE: {
                uint8_t first_byte;
                if (!ring_read_advance(c, &first_byte, 1)) goto done;
                uint8_t format = first_byte >> 6;
                uint8_t csid   = first_byte & 0x3F;
                if (csid == 0) { stop_internal(c, "Two bytes basic header not implemented"); goto done; }
                if (csid == 1) { stop_internal(c, "Three bytes basic header not implemented"); goto done; }
                tvu_irl_media_pipeline_t *p = c->pipeline_slots[csid];
                if (!p) {
                    p = tvu_irl_media_pipeline_create(c, csid);
                    c->pipeline_slots[csid] = p;
                }
                c->current_pipeline = p;
                switch (format) {
                    case 0: c->chunk_state = CHUNK_MSG_HEADER_TYPE0; break;
                    case 1: c->chunk_state = CHUNK_MSG_HEADER_TYPE1; break;
                    case 2: c->chunk_state = CHUNK_MSG_HEADER_TYPE2; break;
                    case 3:
                        if (tvu_irl_media_pipeline_extended_timestamp_present_in_type3(c->current_pipeline)) {
                            c->chunk_state = CHUNK_EXTENDED_TIMESTAMP;
                        } else {
                            int64_t size = tvu_irl_media_pipeline_next_chunk_data_size(c->current_pipeline);
                            if (size <= 0) { stop_internal(c, "Unexpected data"); goto done; }
                            c->chunk_state = CHUNK_DATA;
                            c->receive_size = size;
                        }
                        break;
                    default: stop_internal(c, "Invalid chunk format"); goto done;
                }
                break;
            }
            case CHUNK_MSG_HEADER_TYPE0: {
                uint8_t b[11];
                if (!ring_read_advance(c, b, 11)) goto done;
                tvu_irl_media_pipeline_set_is_absolute_timestamp(c->current_pipeline, true);
                uint32_t ts = ((uint32_t)b[0] << 16) | ((uint32_t)b[1] << 8) | b[2];
                int64_t len = (int64_t)(((uint32_t)b[3] << 16) | ((uint32_t)b[4] << 8) | b[5]);
                tvu_irl_media_pipeline_set_message_timestamp(c->current_pipeline, ts);
                tvu_irl_media_pipeline_set_message_length(c->current_pipeline, len);
                tvu_irl_media_pipeline_set_message_type_id(c->current_pipeline, b[6]);
                uint32_t sid = (uint32_t)b[7] | ((uint32_t)b[8] << 8) | ((uint32_t)b[9] << 16) | ((uint32_t)b[10] << 24);
                tvu_irl_media_pipeline_set_message_stream_id(c->current_pipeline, sid);
                if (ts == 0xFFFFFF) {
                    tvu_irl_media_pipeline_set_extended_timestamp_present_in_type3(c->current_pipeline, true);
                    c->chunk_state = CHUNK_EXTENDED_TIMESTAMP;
                } else {
                    tvu_irl_media_pipeline_set_extended_timestamp_present_in_type3(c->current_pipeline, false);
                    int64_t size = tvu_irl_media_pipeline_next_chunk_data_size(c->current_pipeline);
                    if (size <= 0) { stop_internal(c, "Unexpected data"); goto done; }
                    c->chunk_state = CHUNK_DATA;
                    c->receive_size = size;
                }
                break;
            }
            case CHUNK_MSG_HEADER_TYPE1: {
                uint8_t b[7];
                if (!ring_read_advance(c, b, 7)) goto done;
                tvu_irl_media_pipeline_set_is_absolute_timestamp(c->current_pipeline, false);
                uint32_t ts = ((uint32_t)b[0] << 16) | ((uint32_t)b[1] << 8) | b[2];
                int64_t len = (int64_t)(((uint32_t)b[3] << 16) | ((uint32_t)b[4] << 8) | b[5]);
                tvu_irl_media_pipeline_set_message_timestamp(c->current_pipeline, ts);
                tvu_irl_media_pipeline_set_message_length(c->current_pipeline, len);
                tvu_irl_media_pipeline_set_message_type_id(c->current_pipeline, b[6]);
                if (ts == 0xFFFFFF) {
                    tvu_irl_media_pipeline_set_extended_timestamp_present_in_type3(c->current_pipeline, true);
                    c->chunk_state = CHUNK_EXTENDED_TIMESTAMP;
                } else {
                    tvu_irl_media_pipeline_set_extended_timestamp_present_in_type3(c->current_pipeline, false);
                    int64_t size = tvu_irl_media_pipeline_next_chunk_data_size(c->current_pipeline);
                    if (size <= 0) { stop_internal(c, "Unexpected data"); goto done; }
                    c->chunk_state = CHUNK_DATA;
                    c->receive_size = size;
                }
                break;
            }
            case CHUNK_MSG_HEADER_TYPE2: {
                uint8_t b[3];
                if (!ring_read_advance(c, b, 3)) goto done;
                tvu_irl_media_pipeline_set_is_absolute_timestamp(c->current_pipeline, false);
                uint32_t ts = ((uint32_t)b[0] << 16) | ((uint32_t)b[1] << 8) | b[2];
                tvu_irl_media_pipeline_set_message_timestamp(c->current_pipeline, ts);
                if (ts == 0xFFFFFF) {
                    tvu_irl_media_pipeline_set_extended_timestamp_present_in_type3(c->current_pipeline, true);
                    c->chunk_state = CHUNK_EXTENDED_TIMESTAMP;
                } else {
                    tvu_irl_media_pipeline_set_extended_timestamp_present_in_type3(c->current_pipeline, false);
                    int64_t size = tvu_irl_media_pipeline_next_chunk_data_size(c->current_pipeline);
                    if (size <= 0) { stop_internal(c, "Unexpected data"); goto done; }
                    c->chunk_state = CHUNK_DATA;
                    c->receive_size = size;
                }
                break;
            }
            case CHUNK_EXTENDED_TIMESTAMP: {
                uint8_t b[4];
                if (!ring_read_advance(c, b, 4)) goto done;
                uint32_t ts = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16)
                            | ((uint32_t)b[2] << 8)  | (uint32_t)b[3];
                tvu_irl_media_pipeline_set_message_timestamp(c->current_pipeline, ts);
                int64_t size = tvu_irl_media_pipeline_next_chunk_data_size(c->current_pipeline);
                if (size <= 0) { stop_internal(c, "Unexpected data"); goto done; }
                c->chunk_state = CHUNK_DATA;
                c->receive_size = size;
                break;
            }
            case CHUNK_DATA: {
                int64_t needed = c->receive_size;
                if (c->ring.used < needed) goto done;
                maybe_enable_receive_batch_mode(c);
                ring_consume_to_pipeline(c, needed, c->current_pipeline);
                c->chunk_state = CHUNK_BASIC_HEADER_FIRST_BYTE;
                break;
            }
        }
    }

done:
    if (c->total_bytes_received - c->total_bytes_received_acked > (uint64_t)c->window_ack_size) {
        send_ack(c);
        c->total_bytes_received_acked = c->total_bytes_received;
    }
}

/* Transport 回调 trampoline */
static void on_transport_receive(const uint8_t *data, size_t length, void *user) {
    tvu_irl_stream_connection_t *c = (tvu_irl_stream_connection_t *)user;
    process_received(c, data, length);
}

static void on_transport_failure(int error_code, void *user) {
    tvu_irl_stream_connection_t *c = (tvu_irl_stream_connection_t *)user;
    char buf[64];
    if (error_code == 0) {
        stop_internal(c, "Disconnected");
    } else {
        snprintf(buf, sizeof(buf), "Network error %d", error_code);
        stop_internal(c, buf);
    }
}

void tvu_irl_stream_connection_start(tvu_irl_stream_connection_t *c) {
    if (!c) return;
    atomic_store(&c->lifecycle, TVU_IRL_LIFECYCLE_CONNECTING);
    dispatch_queue_t q = tvu_irl_streaming_server_queue(c->server);
    tvu_irl_connection_start(c->transport, q, on_transport_receive, on_transport_failure, c);
}

/* ============================== 字段访问 ============================== */

tvu_irl_streaming_server_t *tvu_irl_stream_connection_server(tvu_irl_stream_connection_t *c) { return c->server; }
const char *tvu_irl_stream_connection_stream_key(const tvu_irl_stream_connection_t *c) { return c->stream_key.data ? c->stream_key.data : ""; }
int32_t tvu_irl_stream_connection_latency_ms(const tvu_irl_stream_connection_t *c) { return c->latency_ms; }
double  tvu_irl_stream_connection_last_video_rtmp_ts(const tvu_irl_stream_connection_t *c) {
    return atomic_load(&((tvu_irl_stream_connection_t *)c)->last_video_rtmp_ts);
}
void tvu_irl_stream_connection_set_last_video_rtmp_ts(tvu_irl_stream_connection_t *c, double ts) {
    atomic_store(&c->last_video_rtmp_ts, ts);
}
const uint8_t *tvu_irl_stream_connection_camera_id(const tvu_irl_stream_connection_t *c) { return c->camera_id; }
CFAbsoluteTime tvu_irl_stream_connection_latest_receive_time(const tvu_irl_stream_connection_t *c) { return c->latest_receive_abs_time; }
tvu_irl_lifecycle_t tvu_irl_stream_connection_lifecycle(const tvu_irl_stream_connection_t *c) {
    return (tvu_irl_lifecycle_t)atomic_load(&((tvu_irl_stream_connection_t *)c)->lifecycle);
}

int32_t tvu_irl_stream_connection_chunk_size_from_client(const tvu_irl_stream_connection_t *c) { return c->chunk_size_from_client; }
int32_t tvu_irl_stream_connection_chunk_size_to_client(const tvu_irl_stream_connection_t *c) { return c->chunk_size_to_client; }
void tvu_irl_stream_connection_set_chunk_size_from_client(tvu_irl_stream_connection_t *c, int32_t v) { c->chunk_size_from_client = v; }
void tvu_irl_stream_connection_set_chunk_size_to_client(tvu_irl_stream_connection_t *c, int32_t v) { c->chunk_size_to_client = v; }
void tvu_irl_stream_connection_set_window_ack_size(tvu_irl_stream_connection_t *c, int32_t v) { c->window_ack_size = v; }
void tvu_irl_stream_connection_complete_publish(tvu_irl_stream_connection_t *c,
                                                const char *stream_key,
                                                int32_t latency_ms,
                                                const uint8_t uuid[16]) {
    tvu_irl_str_set(&c->stream_key, tvu_irl_strv_from_cstr(stream_key));
    c->latency_ms = latency_ms;
    memcpy(c->camera_id, uuid, 16);
    atomic_store(&c->lifecycle, TVU_IRL_LIFECYCLE_CONNECTED);
    tvu_irl_streaming_server_connection_did_complete(c->server, c);
}

/* ============================== Pipeline → Connection 回调 ============================== */

void tvu_irl_stream_connection_pipeline_produced_video_sample(
    tvu_irl_stream_connection_t *c, CMSampleBufferRef sb) {
    tvu_irl_streaming_server_forward_video_sample(c->server, sb);
}
void tvu_irl_stream_connection_pipeline_produced_video_image(
    tvu_irl_stream_connection_t *c, CVImageBufferRef ib) {
    tvu_irl_streaming_server_forward_video_image(c->server, ib);
}
void tvu_irl_stream_connection_pipeline_produced_audio_sample(
    tvu_irl_stream_connection_t *c, CMSampleBufferRef sb) {
    tvu_irl_streaming_server_forward_audio_sample(c->server, sb);
}
void tvu_irl_stream_connection_pipeline_observed_audio_pts(tvu_irl_stream_connection_t *c, double pts) {
    tvu_irl_media_clock_set_audio_pts(&c->media_clock, pts);
    tvu_irl_media_clock_decision_t d = tvu_irl_media_clock_update(&c->media_clock);
    if (d.has_update) {
        tvu_irl_streaming_server_forward_target_latencies(c->server, d.video_target_latency, d.audio_target_latency);
    }
}
void tvu_irl_stream_connection_pipeline_observed_video_pts(tvu_irl_stream_connection_t *c, double pts) {
    tvu_irl_media_clock_set_video_pts(&c->media_clock, pts);
    tvu_irl_media_clock_decision_t d = tvu_irl_media_clock_update(&c->media_clock);
    if (d.has_update) {
        tvu_irl_streaming_server_forward_target_latencies(c->server, d.video_target_latency, d.audio_target_latency);
    }
}

double tvu_irl_stream_connection_base_pts_ms(tvu_irl_stream_connection_t *c) {
    if (!c->has_base_pts) {
        c->base_pts_ms_value = 1000.0 * CACurrentMediaTime();
        c->has_base_pts = true;
    }
    return c->base_pts_ms_value;
}

/* ============================== PTS Anchor ============================== */

static CMTime remap_video_pts(CMTime pts, void *user) {
    tvu_irl_stream_connection_t *c = (tvu_irl_stream_connection_t *)user;
    if (!CMTIME_IS_VALID(pts)) return pts;
    CFTimeInterval now_sec = CACurrentMediaTime();

    static const int32_t kBasetimeScale = 1000000;       /* 微秒 */
    static const double kEmaAlpha = 0.005;
    static const double kPllGain  = 0.01;
    static const double kMaxCorrectionMsPerFrame = 1.0;
    static const double kInsaneDriftMs = 5000.0;

    os_unfair_lock_lock(&c->anchor_lock);
    if (!c->video_first_pts_ready) {
        c->video_first_pts = pts;
        c->video_first_pts_ready = true;
    }
    if (!c->anchor_basetime_ready) {
        c->anchor_basetime = CMTimeMakeWithSeconds(now_sec, kBasetimeScale);
        c->anchor_basetime_ready = true;
    }
    CMTime source_delta = CMTimeSubtract(pts, c->video_first_pts);
    CMTime new_pts = CMTimeAdd(c->anchor_basetime, source_delta);
    double new_pts_sec = CMTimeGetSeconds(new_pts);
    double drift_ms = (new_pts_sec - now_sec) * 1000.0;
    c->filtered_drift_ms = c->filtered_drift_ms * (1.0 - kEmaAlpha) + drift_ms * kEmaAlpha;

    if (fabs(c->filtered_drift_ms) > kInsaneDriftMs) {
        c->anchor_basetime_ready = false;
        c->anchor_basetime = kCMTimeInvalid;
        c->video_first_pts_ready = false;
        c->video_first_pts = kCMTimeInvalid;
        c->audio_first_pts_ready = false;
        c->audio_first_pts = kCMTimeInvalid;
        c->last_audio_new_pts = kCMTimeInvalid;
        c->filtered_drift_ms = 0.0;
        os_unfair_lock_unlock(&c->anchor_lock);
        TVU_IRL_LOG_ERROR("rtmp-server: video PLL PANIC reset (drift=%.0fms)", drift_ms);
        return new_pts;
    }

    double correction_ms = c->filtered_drift_ms * kPllGain;
    if (correction_ms > kMaxCorrectionMsPerFrame) correction_ms = kMaxCorrectionMsPerFrame;
    if (correction_ms < -kMaxCorrectionMsPerFrame) correction_ms = -kMaxCorrectionMsPerFrame;
    int64_t correction_us = (int64_t)llround(correction_ms * 1000.0);
    if (correction_us != 0) {
        c->anchor_basetime = CMTimeSubtract(c->anchor_basetime,
                                             CMTimeMake(correction_us, kBasetimeScale));
    }
    os_unfair_lock_unlock(&c->anchor_lock);
    return new_pts;
}

static CMTime remap_audio_pts(CMTime pts, void *user) {
    tvu_irl_stream_connection_t *c = (tvu_irl_stream_connection_t *)user;
    if (!CMTIME_IS_VALID(pts)) return pts;

    os_unfair_lock_lock(&c->anchor_lock);
    if (!c->anchor_basetime_ready) {
        os_unfair_lock_unlock(&c->anchor_lock);
        return kCMTimeInvalid;     /* video basetime 未就绪 → 音频丢帧 */
    }
    if (!c->audio_first_pts_ready) {
        c->audio_first_pts = pts;
        c->audio_first_pts_ready = true;
    }
    CMTime source_delta = CMTimeSubtract(pts, c->audio_first_pts);
    CMTime new_pts = CMTimeAdd(c->anchor_basetime, source_delta);
    /* 防御性单调 clamp */
    if (CMTIME_IS_VALID(c->last_audio_new_pts) &&
        CMTimeCompare(new_pts, c->last_audio_new_pts) <= 0) {
        new_pts = CMTimeAdd(c->last_audio_new_pts, CMTimeMake(1, pts.timescale));
    }
    c->last_audio_new_pts = new_pts;
    os_unfair_lock_unlock(&c->anchor_lock);
    return new_pts;
}

tvu_irl_decoded_pts_anchor_t tvu_irl_stream_connection_pts_anchor(tvu_irl_stream_connection_t *c) {
    tvu_irl_decoded_pts_anchor_t a = { remap_video_pts, remap_audio_pts, c };
    return a;
}
