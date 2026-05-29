/*
 * tvu_irl_messages.h
 *
 * 替代 TVUIRLProtocolMessage 基类 + 5 个子类：
 *   TVUIRLAckMessage / TVUIRLWindowAckMessage / TVUIRLFlowControl
 *   TVUIRLBandwidthConfig / TVUIRLCommandMessage
 *
 * 不使用 vtable，每个消息独立 struct（共享一个 header 内嵌于第一字段）。
 * Caller 在 build / parse 调用点已知具体类型，polymorphic 调度由 caller 通过
 * type tag 完成（media_packet 等只持有"已编码字节 + header"，不持有 typed
 * struct，避免 vtable 间接跳转）。
 *
 * 内存模型：
 *   - 简单消息（Ack/WindowAck/FlowControl/BandwidthConfig）全是 POD，栈分配
 *   - CommandMessage 持有 owned name + owned command_object + owned arguments 数组；
 *     init / destroy 严格配对
 */

#ifndef TVU_IRL_MESSAGES_H
#define TVU_IRL_MESSAGES_H

#include "tvu_irl_bytes.h"
#include "tvu_irl_str.h"
#include "tvu_irl_amf.h"

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* RTMP message type id（与协议字段对应）。 */
typedef enum {
    TVU_IRL_MSG_CHUNK_SIZE   = 0x01,
    TVU_IRL_MSG_ABORT        = 0x02,
    TVU_IRL_MSG_ACK          = 0x03,
    TVU_IRL_MSG_USER         = 0x04,
    TVU_IRL_MSG_WINDOW_ACK   = 0x05,
    TVU_IRL_MSG_BANDWIDTH    = 0x06,
    TVU_IRL_MSG_AUDIO        = 0x08,
    TVU_IRL_MSG_VIDEO        = 0x09,
    TVU_IRL_MSG_AMF3_DATA    = 0x0F,
    TVU_IRL_MSG_AMF3_COMMAND = 0x11,
    TVU_IRL_MSG_AMF0_DATA    = 0x12,
    TVU_IRL_MSG_AMF0_COMMAND = 0x14,
    TVU_IRL_MSG_AGGREGATE    = 0x16,
} tvu_irl_message_type_t;

typedef enum {
    TVU_IRL_BW_LIMIT_HARD    = 0x00,
    TVU_IRL_BW_LIMIT_SOFT    = 0x01,
    TVU_IRL_BW_LIMIT_DYNAMIC = 0x02,
    TVU_IRL_BW_LIMIT_UNKNOWN = 0xFF,
} tvu_irl_bandwidth_limit_t;

/* 所有 message 的公共首部。message 结构体把它作为第一个字段。 */
typedef struct {
    tvu_irl_message_type_t type;
    int64_t                length;     /* 编码体长度 */
    uint32_t               stream_id;
    uint32_t               timestamp;
} tvu_irl_message_header_t;

/* ---------- Ack (0x03) ---------- */
typedef struct {
    tvu_irl_message_header_t header;
    uint32_t                 sequence;
} tvu_irl_ack_message_t;

void tvu_irl_ack_init(tvu_irl_ack_message_t *m);
void tvu_irl_ack_init_with_sequence(tvu_irl_ack_message_t *m, uint32_t sequence);
void tvu_irl_ack_build_encoded(tvu_irl_ack_message_t *m, tvu_irl_bytes_t *out);
bool tvu_irl_ack_parse(tvu_irl_ack_message_t *m, const uint8_t *data, size_t length);

/* ---------- WindowAck (0x05) ---------- */
typedef struct {
    tvu_irl_message_header_t header;
    uint32_t                 size;
} tvu_irl_window_ack_message_t;

void tvu_irl_window_ack_init(tvu_irl_window_ack_message_t *m);
void tvu_irl_window_ack_init_with_size(tvu_irl_window_ack_message_t *m, uint32_t size);
void tvu_irl_window_ack_build_encoded(tvu_irl_window_ack_message_t *m, tvu_irl_bytes_t *out);
bool tvu_irl_window_ack_parse(tvu_irl_window_ack_message_t *m, const uint8_t *data, size_t length);

/* ---------- Set Chunk Size / FlowControl (0x01) ---------- */
typedef struct {
    tvu_irl_message_header_t header;
    uint32_t                 size;
} tvu_irl_flow_control_t;

void tvu_irl_flow_control_init(tvu_irl_flow_control_t *m);
void tvu_irl_flow_control_init_with_size(tvu_irl_flow_control_t *m, uint32_t size);
void tvu_irl_flow_control_build_encoded(tvu_irl_flow_control_t *m, tvu_irl_bytes_t *out);
bool tvu_irl_flow_control_parse(tvu_irl_flow_control_t *m, const uint8_t *data, size_t length);

/* ---------- BandwidthConfig (0x06) ---------- */
typedef struct {
    tvu_irl_message_header_t header;
    uint32_t                 size;
    tvu_irl_bandwidth_limit_t limit;
} tvu_irl_bandwidth_config_t;

void tvu_irl_bandwidth_config_init(tvu_irl_bandwidth_config_t *m);
void tvu_irl_bandwidth_config_init_with(tvu_irl_bandwidth_config_t *m,
                                        uint32_t size,
                                        tvu_irl_bandwidth_limit_t limit);
void tvu_irl_bandwidth_config_build_encoded(tvu_irl_bandwidth_config_t *m, tvu_irl_bytes_t *out);
bool tvu_irl_bandwidth_config_parse(tvu_irl_bandwidth_config_t *m, const uint8_t *data, size_t length);

/* ---------- CommandMessage (0x14 / 0x11) ---------- */

/* 命令名字面常量（不持有内存）。直接展开为 strv 字面量。 */
#define TVU_IRL_CMD_CONNECT          TVU_IRL_STRV_LITERAL("connect")
#define TVU_IRL_CMD_CLOSE            TVU_IRL_STRV_LITERAL("close")
#define TVU_IRL_CMD_RESULT           TVU_IRL_STRV_LITERAL("_result")
#define TVU_IRL_CMD_ERROR            TVU_IRL_STRV_LITERAL("_error")
#define TVU_IRL_CMD_PUBLISH          TVU_IRL_STRV_LITERAL("publish")
#define TVU_IRL_CMD_CREATE_STREAM    TVU_IRL_STRV_LITERAL("createStream")
#define TVU_IRL_CMD_RELEASE_STREAM   TVU_IRL_STRV_LITERAL("releaseStream")
#define TVU_IRL_CMD_FC_PUBLISH       TVU_IRL_STRV_LITERAL("FCPublish")
#define TVU_IRL_CMD_FC_UNPUBLISH     TVU_IRL_STRV_LITERAL("FCUnpublish")
#define TVU_IRL_CMD_DELETE_STREAM    TVU_IRL_STRV_LITERAL("deleteStream")
#define TVU_IRL_CMD_CLOSE_STREAM     TVU_IRL_STRV_LITERAL("closeStream")
#define TVU_IRL_CMD_ON_STATUS        TVU_IRL_STRV_LITERAL("onStatus")
#define TVU_IRL_CMD_ON_FC_PUBLISH    TVU_IRL_STRV_LITERAL("onFCPublish")
#define TVU_IRL_CMD_UNKNOWN          TVU_IRL_STRV_LITERAL("unknown")

typedef struct {
    tvu_irl_message_header_t header;
    tvu_irl_str_t            command_name;
    int64_t                  transaction_id;
    tvu_irl_amf_value_t     *command_object;   /* owned；nullable */
    tvu_irl_amf_value_t    **arguments;        /* owned 数组，元素 owned */
    size_t                   num_arguments;
    size_t                   arguments_capacity;
} tvu_irl_command_message_t;

/* type 必须是 TVU_IRL_MSG_AMF0_COMMAND 或 TVU_IRL_MSG_AMF3_COMMAND。 */
void tvu_irl_command_message_init(tvu_irl_command_message_t *m,
                                  tvu_irl_message_type_t type,
                                  uint32_t stream_id);
void tvu_irl_command_message_destroy(tvu_irl_command_message_t *m);

void tvu_irl_command_message_set_name(tvu_irl_command_message_t *m, tvu_irl_strv_t name);

/* 转移所有权：caller 之后不应 destroy 传入的 value；NULL 表示清空。 */
void tvu_irl_command_message_set_object(tvu_irl_command_message_t *m,
                                        tvu_irl_amf_value_t *command_object);
void tvu_irl_command_message_add_argument(tvu_irl_command_message_t *m,
                                          tvu_irl_amf_value_t *argument);

void tvu_irl_command_message_build_encoded(tvu_irl_command_message_t *m, tvu_irl_bytes_t *out);

/* 解析二进制 body 到结构体字段。失败返回 false（部分字段可能已填充）。
 * 调用前应 init，调用后无论成功失败都需要 destroy。 */
bool tvu_irl_command_message_parse(tvu_irl_command_message_t *m,
                                   const uint8_t *data, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_MESSAGES_H */
