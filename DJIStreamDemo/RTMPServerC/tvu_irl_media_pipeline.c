/*
 * tvu_irl_media_pipeline.c
 *
 * 单 chunk stream id 的消息处理：
 *   - messageBody raw buffer（Plan 11，替代 NSMutableData，热路径少 1 次 alloc + 1 次 retain/release）
 *   - AMF0 命令分发（connect / createStream / publish）
 *   - 视频：AVC / HEVC 序列头 → format desc → 创建 hardware_decoder；coded frames → sample buffer → decoder
 *   - 音频：AAC ASC → 创建 audio_decoder；AAC raw → decode
 */

#include "tvu_irl_media_pipeline.h"
#include "tvu_irl_stream_connection.h"
#include "tvu_irl_streaming_server.h"
#include "tvu_irl_messages.h"
#include "tvu_irl_amf.h"
#include "tvu_irl_io.h"
#include "tvu_irl_media_packet.h"
#include "tvu_irl_video_config.h"
#include "tvu_irl_audio_config.h"
#include "tvu_irl_hardware_decoder.h"
#include "tvu_irl_audio_decoder.h"
#include "tvu_irl_log.h"

#include <CoreMedia/CoreMedia.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define MSGBODY_INIT_CAP (4 * 1024)
#define MSGBODY_MAX_CAP  (2 * 1024 * 1024)

/* FLV 常量 */
#define FLV_VIDEO_CODEC_AVC       7
#define FLV_VIDEO_CODEC_EXT       0x0F
#define FLV_FRAME_TYPE_KEY        1
#define FLV_AVC_PKT_SEQ           0
#define FLV_AVC_PKT_NAL           1
#define FLV_VIDEO_PKT_SEQ_START   0
#define FLV_VIDEO_PKT_CODED       1
#define FLV_VIDEO_PKT_SEQ_END     2
#define FLV_VIDEO_PKT_CODED_X     3
#define FLV_AAC_PKT_SEQ           0
#define FLV_AAC_PKT_RAW           1
#define FLV_AUDIO_CODEC_AAC       0xA
#define FLV_FOURCC_HEVC           0x68766331u   /* 'hvc1' */
#define FLV_VIDEO_HEADER_SIZE     5
#define FLV_AUDIO_HEADER_SIZE     2

#define RTMP_SERVER_APP "/live"

/* ============================== 内部结构 ============================== */

typedef struct {
    uint8_t *base;
    int64_t  capacity;
    int64_t  length;
} message_body_t;

struct tvu_irl_media_pipeline {
    tvu_irl_stream_connection_t *connection;
    uint16_t                     chunk_stream_id;

    /* chunk header 字段（由 connection 的 parser 写入） */
    uint8_t   message_type_id;
    int64_t   message_length;
    uint32_t  message_timestamp;
    uint32_t  message_stream_id;
    bool      is_absolute_timestamp;
    bool      extended_timestamp_present_in_type3;

    message_body_t body;

    /* 媒体时间戳（基于 RTMP 时间戳累加） */
    double  media_timestamp;
    double  media_timestamp_zero;
    double  video_timestamp;
    bool    has_media_timestamp_zero;
    bool    has_video_timestamp;

    /* 视频解码 */
    tvu_irl_hardware_decoder_t *video_decoder;   /* nullable until first SeqHeader */
    CMVideoFormatDescriptionRef video_format_description;

    /* 音频解码 */
    tvu_irl_audio_decoder_t *audio_decoder;      /* nullable until first AAC SeqHeader */
};

static void process_message(tvu_irl_media_pipeline_t *p);

/* ============================== 生命周期 ============================== */

tvu_irl_media_pipeline_t *tvu_irl_media_pipeline_create(
    tvu_irl_stream_connection_t *connection, uint16_t chunk_stream_id) {
    tvu_irl_media_pipeline_t *p = (tvu_irl_media_pipeline_t *)calloc(1, sizeof(*p));
    if (!p) abort();
    p->connection = connection;
    p->chunk_stream_id = chunk_stream_id;
    p->body.base = (uint8_t *)malloc(MSGBODY_INIT_CAP);
    if (!p->body.base) abort();
    p->body.capacity = MSGBODY_INIT_CAP;
    p->media_timestamp_zero = -1.0;
    p->video_timestamp = -1.0;
    p->is_absolute_timestamp = true;
    return p;
}

void tvu_irl_media_pipeline_stop(tvu_irl_media_pipeline_t *p) {
    if (!p) return;
    if (p->video_decoder) {
        tvu_irl_hardware_decoder_stop(p->video_decoder);
    }
}

void tvu_irl_media_pipeline_destroy(tvu_irl_media_pipeline_t *p) {
    if (!p) return;
    if (p->video_decoder) {
        tvu_irl_hardware_decoder_destroy(p->video_decoder);
        free(p->video_decoder);
    }
    if (p->audio_decoder) {
        tvu_irl_audio_decoder_destroy(p->audio_decoder);
        free(p->audio_decoder);
    }
    if (p->video_format_description) CFRelease(p->video_format_description);
    free(p->body.base);
    free(p);
}

/* ============================== 字段访问 ============================== */

uint8_t  tvu_irl_media_pipeline_message_type_id(const tvu_irl_media_pipeline_t *p) { return p->message_type_id; }
int64_t  tvu_irl_media_pipeline_message_length(const tvu_irl_media_pipeline_t *p) { return p->message_length; }
uint32_t tvu_irl_media_pipeline_message_timestamp(const tvu_irl_media_pipeline_t *p) { return p->message_timestamp; }
bool     tvu_irl_media_pipeline_extended_timestamp_present_in_type3(const tvu_irl_media_pipeline_t *p) {
    return p->extended_timestamp_present_in_type3;
}

void tvu_irl_media_pipeline_set_message_type_id(tvu_irl_media_pipeline_t *p, uint8_t v) { p->message_type_id = v; }
void tvu_irl_media_pipeline_set_message_length(tvu_irl_media_pipeline_t *p, int64_t v) { p->message_length = v; }
void tvu_irl_media_pipeline_set_message_timestamp(tvu_irl_media_pipeline_t *p, uint32_t v) { p->message_timestamp = v; }
void tvu_irl_media_pipeline_set_message_stream_id(tvu_irl_media_pipeline_t *p, uint32_t v) { p->message_stream_id = v; }
void tvu_irl_media_pipeline_set_is_absolute_timestamp(tvu_irl_media_pipeline_t *p, bool v) { p->is_absolute_timestamp = v; }
void tvu_irl_media_pipeline_set_extended_timestamp_present_in_type3(tvu_irl_media_pipeline_t *p, bool v) {
    p->extended_timestamp_present_in_type3 = v;
}

int64_t tvu_irl_media_pipeline_remaining_bytes(const tvu_irl_media_pipeline_t *p) {
    return p->message_length - p->body.length;
}

int64_t tvu_irl_media_pipeline_next_chunk_data_size(const tvu_irl_media_pipeline_t *p) {
    int32_t from_client = tvu_irl_stream_connection_chunk_size_from_client(p->connection);
    int64_t remaining = tvu_irl_media_pipeline_remaining_bytes(p);
    return (from_client < remaining) ? (int64_t)from_client : remaining;
}

/* ============================== Body 追加（热路径，Plan 11） ============================== */

void tvu_irl_media_pipeline_append_chunk_bytes(tvu_irl_media_pipeline_t *p,
                                               const uint8_t *bytes, size_t length) {
    if (length == 0) return;
    int64_t need = p->body.length + (int64_t)length;
    if (__builtin_expect(need > p->body.capacity, 0)) {
        int64_t new_cap = p->body.capacity * 3 / 2;
        if (new_cap < need) new_cap = need;
        if (new_cap > MSGBODY_MAX_CAP) {
            char buf[64];
            snprintf(buf, sizeof(buf), "Message too large: %lld", (long long)need);
            tvu_irl_stream_connection_stop(p->connection, buf);
            return;
        }
        uint8_t *nb = (uint8_t *)realloc(p->body.base, (size_t)new_cap);
        if (!nb) abort();
        p->body.base = nb;
        p->body.capacity = new_cap;
    }
    memcpy(p->body.base + p->body.length, bytes, length);
    p->body.length += length;
    if (tvu_irl_media_pipeline_remaining_bytes(p) == 0) {
        process_message(p);
        p->body.length = 0;
    }
}

/* ============================== 消息分发 ============================== */

static void process_amf0_command(tvu_irl_media_pipeline_t *p);
static void process_chunk_size(tvu_irl_media_pipeline_t *p);
static void process_window_ack(tvu_irl_media_pipeline_t *p);
static void process_video(tvu_irl_media_pipeline_t *p);
static void process_audio(tvu_irl_media_pipeline_t *p);

static void process_message(tvu_irl_media_pipeline_t *p) {
    if (p->is_absolute_timestamp) {
        p->media_timestamp = (double)p->message_timestamp;
    } else {
        p->media_timestamp += (double)p->message_timestamp;
    }
    if (!p->has_media_timestamp_zero) {
        p->media_timestamp_zero = p->media_timestamp;
        p->has_media_timestamp_zero = true;
    }
    switch (p->message_type_id) {
        case TVU_IRL_MSG_AMF0_COMMAND: process_amf0_command(p); break;
        case TVU_IRL_MSG_AMF0_DATA:    /* ignore */            break;
        case TVU_IRL_MSG_CHUNK_SIZE:   process_chunk_size(p); break;
        case TVU_IRL_MSG_WINDOW_ACK:   process_window_ack(p); break;
        case TVU_IRL_MSG_VIDEO:        process_video(p);     break;
        case TVU_IRL_MSG_AUDIO:        process_audio(p);     break;
        default:
            TVU_IRL_LOG("rtmp-server: unsupported message type 0x%02x", p->message_type_id);
            break;
    }
}

/* ============================== 发包辅助 ============================== */

static void send_packet(tvu_irl_media_pipeline_t *p,
                        uint16_t csid,
                        tvu_irl_message_type_t msg_type,
                        uint32_t msg_stream_id,
                        uint32_t msg_timestamp,
                        const uint8_t *body, size_t body_length) {
    int32_t max_chunk = tvu_irl_stream_connection_chunk_size_to_client(p->connection);
    tvu_irl_bytes_t out; tvu_irl_bytes_init(&out);
    tvu_irl_media_packet_emit(TVU_IRL_PACKET_TYPE_ZERO, csid, msg_type,
                              msg_stream_id, msg_timestamp,
                              body, body_length, (size_t)max_chunk, &out);
    tvu_irl_stream_connection_send_bytes(p->connection, out.data, out.length);
    tvu_irl_bytes_destroy(&out);
}

/* ============================== AMF0 Command ============================== */

static void send_command_reply(tvu_irl_media_pipeline_t *p,
                               tvu_irl_strv_t name,
                               int64_t transaction_id,
                               tvu_irl_amf_value_t *info_obj_owned) {
    tvu_irl_command_message_t cmd;
    tvu_irl_command_message_init(&cmd, TVU_IRL_MSG_AMF0_COMMAND, p->message_stream_id);
    tvu_irl_command_message_set_name(&cmd, name);
    cmd.transaction_id = transaction_id;
    if (info_obj_owned) {
        tvu_irl_command_message_add_argument(&cmd, info_obj_owned);
    }
    tvu_irl_bytes_t body; tvu_irl_bytes_init(&body);
    tvu_irl_command_message_build_encoded(&cmd, &body);
    send_packet(p, p->chunk_stream_id, TVU_IRL_MSG_AMF0_COMMAND,
                p->message_stream_id, 0, body.data, body.length);
    tvu_irl_bytes_destroy(&body);
    tvu_irl_command_message_destroy(&cmd);
}

static void handle_connect(tvu_irl_media_pipeline_t *p, int64_t transaction_id,
                           const tvu_irl_amf_value_t *cmd_object) {
    const tvu_irl_amf_value_t *tcurl_val = tvu_irl_amf_object_get(cmd_object, TVU_IRL_STRV_LITERAL("tcUrl"));
    if (!tcurl_val || tcurl_val->type != TVU_IRL_AMF_STRING) {
        tvu_irl_stream_connection_stop(p->connection, "Stream URL missing");
        return;
    }
    /* 简化的 URL 路径校验：必须包含 "/live"（精确匹配 path） */
    tvu_irl_strv_t tcurl = tvu_irl_str_view(&tcurl_val->str);
    const char *slash = NULL;
    /* 跳过 scheme://host[:port] 找到 path 起点 */
    if (tcurl.length > 8) {
        const char *p_dat = tcurl.data;
        /* 找第三个 "/" */
        size_t i, count = 0;
        for (i = 0; i < tcurl.length; i++) {
            if (p_dat[i] == '/') { count++; if (count == 3) { slash = p_dat + i; break; } }
        }
    }
    if (!slash) {
        tvu_irl_stream_connection_stop(p->connection, "Invalid stream URL");
        return;
    }
    size_t path_len = tcurl.length - (size_t)(slash - tcurl.data);
    if (path_len != strlen(RTMP_SERVER_APP) || memcmp(slash, RTMP_SERVER_APP, path_len) != 0) {
        tvu_irl_stream_connection_stop(p->connection, "Not a camera path");
        return;
    }

    /* 发送 WindowAck + BandwidthConfig + SetChunkSize */
    {
        tvu_irl_window_ack_message_t m; tvu_irl_window_ack_init_with_size(&m, 500000);
        tvu_irl_bytes_t b; tvu_irl_bytes_init(&b);
        tvu_irl_window_ack_build_encoded(&m, &b);
        send_packet(p, TVU_IRL_CSID_CONTROL, TVU_IRL_MSG_WINDOW_ACK, 0, 0, b.data, b.length);
        tvu_irl_bytes_destroy(&b);
    }
    {
        tvu_irl_bandwidth_config_t m;
        tvu_irl_bandwidth_config_init_with(&m, 10000000, TVU_IRL_BW_LIMIT_DYNAMIC);
        tvu_irl_bytes_t b; tvu_irl_bytes_init(&b);
        tvu_irl_bandwidth_config_build_encoded(&m, &b);
        send_packet(p, TVU_IRL_CSID_CONTROL, TVU_IRL_MSG_BANDWIDTH, 0, 0, b.data, b.length);
        tvu_irl_bytes_destroy(&b);
    }
    {
        tvu_irl_flow_control_t m; tvu_irl_flow_control_init_with_size(&m, 128);
        tvu_irl_bytes_t b; tvu_irl_bytes_init(&b);
        tvu_irl_flow_control_build_encoded(&m, &b);
        send_packet(p, TVU_IRL_CSID_CONTROL, TVU_IRL_MSG_CHUNK_SIZE, 0, 0, b.data, b.length);
        tvu_irl_bytes_destroy(&b);
    }
    tvu_irl_stream_connection_set_chunk_size_to_client(p->connection, 128);

    /* _result with info object */
    tvu_irl_amf_value_t *info = tvu_irl_amf_new_object();
    tvu_irl_amf_object_set(info, TVU_IRL_STRV_LITERAL("level"),
                           tvu_irl_amf_new_string(TVU_IRL_STRV_LITERAL("status")));
    tvu_irl_amf_object_set(info, TVU_IRL_STRV_LITERAL("code"),
                           tvu_irl_amf_new_string(TVU_IRL_STRV_LITERAL("NetConnection.Connect.Success")));
    tvu_irl_amf_object_set(info, TVU_IRL_STRV_LITERAL("description"),
                           tvu_irl_amf_new_string(TVU_IRL_STRV_LITERAL("Connection succeeded.")));
    send_command_reply(p, TVU_IRL_CMD_RESULT, transaction_id, info);
}

static void handle_create_stream(tvu_irl_media_pipeline_t *p, int64_t transaction_id) {
    /* 回复 _result(streamId=1) */
    tvu_irl_command_message_t cmd;
    tvu_irl_command_message_init(&cmd, TVU_IRL_MSG_AMF0_COMMAND, p->message_stream_id);
    tvu_irl_command_message_set_name(&cmd, TVU_IRL_CMD_RESULT);
    cmd.transaction_id = transaction_id;
    tvu_irl_command_message_add_argument(&cmd, tvu_irl_amf_new_number(1.0));
    tvu_irl_bytes_t body; tvu_irl_bytes_init(&body);
    tvu_irl_command_message_build_encoded(&cmd, &body);
    send_packet(p, p->chunk_stream_id, TVU_IRL_MSG_AMF0_COMMAND,
                p->message_stream_id, 0, body.data, body.length);
    tvu_irl_bytes_destroy(&body);
    tvu_irl_command_message_destroy(&cmd);
}

static void handle_publish(tvu_irl_media_pipeline_t *p, int64_t transaction_id,
                           tvu_irl_amf_value_t **args, size_t num_args) {
    if (num_args == 0 || args[0]->type != TVU_IRL_AMF_STRING) {
        tvu_irl_stream_connection_stop(p->connection, "Missing/invalid publish argument");
        return;
    }
    tvu_irl_strv_t stream_key = tvu_irl_str_view(&args[0]->str);
    const tvu_irl_stream_config_t *cfg = tvu_irl_streaming_server_config(
        tvu_irl_stream_connection_server(p->connection));
    const tvu_irl_stream_profile_t *matched = tvu_irl_stream_config_find(cfg, stream_key);
    if (!matched) {
        char buf[128];
        snprintf(buf, sizeof(buf), "Stream key %.*s not configured",
                 (int)stream_key.length, stream_key.data);
        tvu_irl_stream_connection_stop(p->connection, buf);
        return;
    }
    /* publish 命中：建立 connection state */
    char key_buf[256];
    size_t copy_len = stream_key.length < 255 ? stream_key.length : 255;
    memcpy(key_buf, stream_key.data, copy_len);
    key_buf[copy_len] = '\0';
    tvu_irl_stream_connection_complete_publish(p->connection, key_buf,
                                               matched->latency_ms, matched->uuid);

    tvu_irl_amf_value_t *info = tvu_irl_amf_new_object();
    tvu_irl_amf_object_set(info, TVU_IRL_STRV_LITERAL("level"),
                           tvu_irl_amf_new_string(TVU_IRL_STRV_LITERAL("status")));
    tvu_irl_amf_object_set(info, TVU_IRL_STRV_LITERAL("code"),
                           tvu_irl_amf_new_string(TVU_IRL_STRV_LITERAL("NetStream.Publish.Start")));
    tvu_irl_amf_object_set(info, TVU_IRL_STRV_LITERAL("description"),
                           tvu_irl_amf_new_string(TVU_IRL_STRV_LITERAL("Start publishing.")));
    send_command_reply(p, TVU_IRL_CMD_ON_STATUS, transaction_id, info);
}

static void process_amf0_command(tvu_irl_media_pipeline_t *p) {
    tvu_irl_reader_t r;
    tvu_irl_reader_init(&r, p->body.base, (size_t)p->body.length);

    tvu_irl_amf_value_t *name_val = tvu_irl_amf_decode(&r);
    if (!name_val || name_val->type != TVU_IRL_AMF_STRING) {
        if (name_val) tvu_irl_amf_destroy(name_val);
        tvu_irl_stream_connection_stop(p->connection, "AMF decode error: name");
        return;
    }
    tvu_irl_strv_t name = tvu_irl_str_view(&name_val->str);

    tvu_irl_amf_value_t *tid_val = tvu_irl_amf_decode(&r);
    int64_t transaction_id = (tid_val && tid_val->type == TVU_IRL_AMF_NUMBER) ? (int64_t)tid_val->num : 0;

    tvu_irl_amf_value_t *cmd_obj_val = tvu_irl_amf_decode(&r);
    /* arguments */
    tvu_irl_amf_value_t *args[8] = {0};
    size_t num_args = 0;
    while (tvu_irl_reader_available(&r) > 0 && num_args < 8) {
        tvu_irl_amf_value_t *v = tvu_irl_amf_decode(&r);
        if (!v) break;
        args[num_args++] = v;
    }

    if (tvu_irl_strv_equals(name, TVU_IRL_CMD_CONNECT)) {
        handle_connect(p, transaction_id, cmd_obj_val);
    } else if (tvu_irl_strv_equals(name, TVU_IRL_CMD_CREATE_STREAM)) {
        handle_create_stream(p, transaction_id);
    } else if (tvu_irl_strv_equals(name, TVU_IRL_CMD_PUBLISH)) {
        handle_publish(p, transaction_id, args, num_args);
    } else if (tvu_irl_strv_equals(name, TVU_IRL_CMD_FC_PUBLISH)
            || tvu_irl_strv_equals(name, TVU_IRL_CMD_FC_UNPUBLISH)
            || tvu_irl_strv_equals(name, TVU_IRL_CMD_DELETE_STREAM)) {
        /* no-op */
    } else {
        TVU_IRL_LOG("rtmp-server: unsupported command %.*s",
                    (int)name.length, name.data);
    }

    if (name_val) tvu_irl_amf_destroy(name_val);
    if (tid_val)  tvu_irl_amf_destroy(tid_val);
    if (cmd_obj_val) tvu_irl_amf_destroy(cmd_obj_val);
    for (size_t i = 0; i < num_args; i++) tvu_irl_amf_destroy(args[i]);
}

/* ============================== Control ============================== */

static void process_chunk_size(tvu_irl_media_pipeline_t *p) {
    if (p->body.length != 4) {
        tvu_irl_stream_connection_stop(p->connection, "Not 4 bytes chunk size");
        return;
    }
    const uint8_t *b = p->body.base;
    uint32_t value = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16)
                   | ((uint32_t)b[2] << 8) | b[3];
    tvu_irl_stream_connection_set_chunk_size_from_client(p->connection, (int32_t)value);
    TVU_IRL_LOG("rtmp-server: chunk size from client: %u", value);
}

static void process_window_ack(tvu_irl_media_pipeline_t *p) {
    if (p->body.length != 4) {
        tvu_irl_stream_connection_stop(p->connection, "Not 4 bytes window ack");
        return;
    }
    const uint8_t *b = p->body.base;
    uint32_t value = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16)
                   | ((uint32_t)b[2] << 8) | b[3];
    tvu_irl_stream_connection_set_window_ack_size(p->connection, (int32_t)value);
    TVU_IRL_LOG("rtmp-server: window ack size from client: %u", value);
}

/* ============================== Video decoder 创建 / 回调 ============================== */

static void on_video_sample_buffer(CMSampleBufferRef sb, void *user) {
    tvu_irl_media_pipeline_t *p = (tvu_irl_media_pipeline_t *)user;
    tvu_irl_stream_connection_pipeline_produced_video_sample(p->connection, sb);
}
static void on_video_image_buffer(CVImageBufferRef ib, void *user) {
    tvu_irl_media_pipeline_t *p = (tvu_irl_media_pipeline_t *)user;
    tvu_irl_stream_connection_pipeline_produced_video_image(p->connection, ib);
}
static void on_audio_sample_buffer(CMSampleBufferRef sb, void *user) {
    tvu_irl_media_pipeline_t *p = (tvu_irl_media_pipeline_t *)user;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    tvu_irl_stream_connection_pipeline_observed_audio_pts(p->connection, CMTimeGetSeconds(pts));
    tvu_irl_stream_connection_pipeline_produced_audio_sample(p->connection, sb);
}

static void setup_video_decoder_if_needed(tvu_irl_media_pipeline_t *p) {
    if (p->video_decoder) return;
    if (!p->video_format_description) return;
    p->video_decoder = (tvu_irl_hardware_decoder_t *)calloc(1, sizeof(*p->video_decoder));
    if (!p->video_decoder) abort();
    dispatch_queue_t q = tvu_irl_streaming_server_queue(
        tvu_irl_stream_connection_server(p->connection));
    tvu_irl_hardware_decoder_init(p->video_decoder, q);
    tvu_irl_hw_decoder_callbacks_t cb = {
        .on_sample_buffer = on_video_sample_buffer,
        .on_image_buffer  = on_video_image_buffer,
        .user             = p,
    };
    tvu_irl_hardware_decoder_set_callbacks(p->video_decoder, cb);
    tvu_irl_hardware_decoder_set_anchor(p->video_decoder,
        tvu_irl_stream_connection_pts_anchor(p->connection));
    tvu_irl_hardware_decoder_start(p->video_decoder, p->video_format_description);
}

/* ============================== Video ============================== */

static bool check_body_at_least(tvu_irl_media_pipeline_t *p, int64_t minimum) {
    if (p->body.length < minimum) {
        char buf[80];
        snprintf(buf, sizeof(buf), "Body too short: %lld < %lld",
                 (long long)p->body.length, (long long)minimum);
        tvu_irl_stream_connection_stop(p->connection, buf);
        return false;
    }
    return true;
}

static int32_t read_composition_time_at(const tvu_irl_media_pipeline_t *p, int64_t offset) {
    if (p->body.length < offset + 3) return 0;
    const uint8_t *b = p->body.base;
    int32_t v = (int32_t)(((uint32_t)b[offset] << 24)
                        | ((uint32_t)b[offset + 1] << 16)
                        | ((uint32_t)b[offset + 2] << 8));
    return v >> 8;   /* 算术右移做符号扩展 */
}

static void set_sample_attachment_is_key(CMSampleBufferRef sb, bool is_key) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    if (!attachments || CFArrayGetCount(attachments) == 0) return;
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    if (is_key) {
        CFDictionaryRemoveValue(dict, kCMSampleAttachmentKey_NotSync);
    } else {
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
    }
}

static void emit_video_frame(tvu_irl_media_pipeline_t *p, bool is_key,
                             int32_t composition_time, int64_t data_offset) {
    if (!p->video_format_description) return;
    if (p->body.length <= data_offset) return;

    int64_t length = p->body.length - data_offset;
    int64_t duration = 0;
    if (p->has_video_timestamp) {
        duration = (int64_t)((p->media_timestamp - p->media_timestamp_zero) - p->video_timestamp);
    }
    p->video_timestamp = p->media_timestamp - p->media_timestamp_zero;
    p->has_video_timestamp = true;
    tvu_irl_stream_connection_set_last_video_rtmp_ts(p->connection, p->video_timestamp);

    double base = tvu_irl_stream_connection_base_pts_ms(p->connection);
    int32_t latency_ms = tvu_irl_stream_connection_latency_ms(p->connection);
    int64_t pts_ms = (int64_t)(p->video_timestamp + base) + (int64_t)(composition_time + latency_ms);
    int64_t dts_ms = (int64_t)(p->video_timestamp + base) + (int64_t)latency_ms;

    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(duration, 1000),
        .presentationTimeStamp = CMTimeMake(pts_ms, 1000),
        .decodeTimeStamp       = CMTimeMake(dts_ms, 1000),
    };
    CMBlockBufferRef block = NULL;
    OSStatus s = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, length, kCFAllocatorDefault, NULL, 0, length,
        kCMBlockBufferAssureMemoryNowFlag, &block);
    if (s != noErr || !block) return;
    CMBlockBufferReplaceDataBytes(p->body.base + data_offset, block, 0, length);
    CMSampleBufferRef sb = NULL;
    size_t sample_size = (size_t)length;
    s = CMSampleBufferCreate(
        kCFAllocatorDefault, block, true, NULL, NULL,
        p->video_format_description, 1, 1, &timing, 1, &sample_size, &sb);
    CFRelease(block);
    if (s != noErr || !sb) return;
    set_sample_attachment_is_key(sb, is_key);
    tvu_irl_stream_connection_pipeline_observed_video_pts(p->connection, (double)pts_ms / 1000.0);
    if (p->video_decoder) tvu_irl_hardware_decoder_decode(p->video_decoder, sb);
    CFRelease(sb);
}

static void process_avc_sequence_start(tvu_irl_media_pipeline_t *p) {
    if (!check_body_at_least(p, FLV_VIDEO_HEADER_SIZE)) return;
    tvu_irl_video_config_avc_t cfg;
    tvu_irl_video_config_avc_init(&cfg);
    if (tvu_irl_video_config_avc_parse(&cfg, p->body.base + FLV_VIDEO_HEADER_SIZE,
                                       (size_t)(p->body.length - FLV_VIDEO_HEADER_SIZE))) {
        CMVideoFormatDescriptionRef desc = NULL;
        OSStatus s = tvu_irl_video_config_avc_make_format_description(&cfg, &desc);
        if (s == noErr) {
            if (p->video_format_description) CFRelease(p->video_format_description);
            p->video_format_description = desc;
            setup_video_decoder_if_needed(p);
        } else {
            if (desc) CFRelease(desc);
            char buf[64];
            snprintf(buf, sizeof(buf), "H.264 format desc error %d", (int)s);
            tvu_irl_stream_connection_stop(p->connection, buf);
        }
    }
    tvu_irl_video_config_avc_destroy(&cfg);
}

static void process_hevc_sequence_start(tvu_irl_media_pipeline_t *p) {
    if (!check_body_at_least(p, FLV_VIDEO_HEADER_SIZE)) return;
    tvu_irl_video_config_hevc_t cfg;
    tvu_irl_video_config_hevc_init(&cfg);
    if (tvu_irl_video_config_hevc_parse(&cfg, p->body.base + FLV_VIDEO_HEADER_SIZE,
                                        (size_t)(p->body.length - FLV_VIDEO_HEADER_SIZE))) {
        CMVideoFormatDescriptionRef desc = NULL;
        OSStatus s = tvu_irl_video_config_hevc_make_format_description(&cfg, &desc);
        if (s == noErr) {
            if (p->video_format_description) CFRelease(p->video_format_description);
            p->video_format_description = desc;
            setup_video_decoder_if_needed(p);
        } else {
            if (desc) CFRelease(desc);
            char buf[64];
            snprintf(buf, sizeof(buf), "H.265 format desc error %d", (int)s);
            tvu_irl_stream_connection_stop(p->connection, buf);
        }
    }
    tvu_irl_video_config_hevc_destroy(&cfg);
}

static void process_video_default_header(tvu_irl_media_pipeline_t *p, uint8_t control) {
    uint8_t codec_id = control & 0x0F;
    if (codec_id != FLV_VIDEO_CODEC_AVC) {
        char buf[64];
        snprintf(buf, sizeof(buf), "Unsupported video codec %u", codec_id);
        tvu_irl_stream_connection_stop(p->connection, buf);
        return;
    }
    if (p->body.length < 2) return;
    uint8_t pkt_type = p->body.base[1];
    if (pkt_type == FLV_AVC_PKT_SEQ) {
        process_avc_sequence_start(p);
    } else if (pkt_type == FLV_AVC_PKT_NAL) {
        if (p->body.length <= 9) return;
        bool is_key = ((p->body.base[0] >> 4) & 0x07) == FLV_FRAME_TYPE_KEY;
        int32_t ct = read_composition_time_at(p, 2);
        emit_video_frame(p, is_key, ct, FLV_VIDEO_HEADER_SIZE);
    } else {
        TVU_IRL_LOG("rtmp-server: unsupported AVC packet type %u", pkt_type);
    }
}

static void process_video_extended_header(tvu_irl_media_pipeline_t *p, uint8_t control) {
    if (!check_body_at_least(p, 5)) return;
    uint8_t frame_type = (control >> 4) & 0x07;
    uint8_t pkt_type   = control & 0x0F;
    const uint8_t *b = p->body.base;
    uint32_t fourcc = ((uint32_t)b[1] << 24) | ((uint32_t)b[2] << 16)
                    | ((uint32_t)b[3] << 8)  | (uint32_t)b[4];
    if (fourcc != FLV_FOURCC_HEVC) {
        char buf[64];
        snprintf(buf, sizeof(buf), "Unsupported fourCC 0x%08x", fourcc);
        tvu_irl_stream_connection_stop(p->connection, buf);
        return;
    }
    bool is_key = (frame_type == FLV_FRAME_TYPE_KEY);
    if (p->body.length <= 9 && pkt_type != FLV_VIDEO_PKT_SEQ_START && pkt_type != FLV_VIDEO_PKT_SEQ_END) {
        return;
    }
    switch (pkt_type) {
        case FLV_VIDEO_PKT_SEQ_START:
            process_hevc_sequence_start(p);
            break;
        case FLV_VIDEO_PKT_CODED:
            emit_video_frame(p, is_key, read_composition_time_at(p, 5), FLV_VIDEO_HEADER_SIZE + 3);
            break;
        case FLV_VIDEO_PKT_SEQ_END:
            tvu_irl_stream_connection_stop(p->connection, "Stream ended");
            break;
        case FLV_VIDEO_PKT_CODED_X:
            emit_video_frame(p, is_key, 0, FLV_VIDEO_HEADER_SIZE);
            break;
        default:
            TVU_IRL_LOG("rtmp-server: unsupported video packet type %u", pkt_type);
            break;
    }
}

static void process_video(tvu_irl_media_pipeline_t *p) {
    if (!check_body_at_least(p, 2)) return;
    uint8_t control = p->body.base[0];
    bool is_ex = (control & FLV_VIDEO_CODEC_EXT) == FLV_VIDEO_CODEC_EXT;
    if (is_ex) process_video_extended_header(p, control);
    else       process_video_default_header(p, control);
}

/* ============================== Audio ============================== */

static void process_aac_sequence_start(tvu_irl_media_pipeline_t *p) {
    if (p->body.length <= FLV_AUDIO_HEADER_SIZE) return;
    tvu_irl_audio_config_t cfg;
    if (!tvu_irl_audio_config_parse(&cfg,
                                    p->body.base + FLV_AUDIO_HEADER_SIZE,
                                    (size_t)(p->body.length - FLV_AUDIO_HEADER_SIZE))) {
        TVU_IRL_LOG("rtmp-server: failed to parse AudioSpecificConfig");
        return;
    }
    if (!p->audio_decoder) {
        p->audio_decoder = (tvu_irl_audio_decoder_t *)calloc(1, sizeof(*p->audio_decoder));
        if (!p->audio_decoder) abort();
        tvu_irl_audio_decoder_init(p->audio_decoder);
        tvu_irl_audio_decoder_callbacks_t cb = {
            .on_sample_buffer = on_audio_sample_buffer,
            .user             = p,
        };
        tvu_irl_audio_decoder_set_callbacks(p->audio_decoder, cb);
        tvu_irl_audio_decoder_set_anchor(p->audio_decoder,
            tvu_irl_stream_connection_pts_anchor(p->connection));
    }
    tvu_irl_audio_decoder_configure(p->audio_decoder, &cfg);
}

static void process_aac_raw(tvu_irl_media_pipeline_t *p) {
    if (!p->audio_decoder || !tvu_irl_audio_decoder_is_ready(p->audio_decoder)) return;
    int64_t length = p->body.length - FLV_AUDIO_HEADER_SIZE;
    if (length <= 0) return;
    double audio_ts = p->media_timestamp - p->media_timestamp_zero;
    double base = tvu_irl_stream_connection_base_pts_ms(p->connection);
    int32_t latency_ms = tvu_irl_stream_connection_latency_ms(p->connection);
    int64_t pts_ms = (int64_t)(audio_ts + base) + (int64_t)latency_ms;
    tvu_irl_audio_decoder_decode_aac(p->audio_decoder,
                                     p->body.base + FLV_AUDIO_HEADER_SIZE,
                                     (size_t)length,
                                     CMTimeMake(pts_ms, 1000));
}

static void process_audio(tvu_irl_media_pipeline_t *p) {
    if (!check_body_at_least(p, 2)) return;
    uint8_t control = p->body.base[0];
    uint8_t codec = control >> 4;
    if (codec != FLV_AUDIO_CODEC_AAC) {
        char buf[64];
        snprintf(buf, sizeof(buf), "Unsupported audio codec %u", codec);
        tvu_irl_stream_connection_stop(p->connection, buf);
        return;
    }
    uint8_t pkt_type = p->body.base[1];
    if (pkt_type == FLV_AAC_PKT_SEQ)      process_aac_sequence_start(p);
    else if (pkt_type == FLV_AAC_PKT_RAW) process_aac_raw(p);
}
