/*
 * tvu_irl_messages.c
 *
 * 所有 build_* 函数遵循同一约定：
 *   - 调用前不要求 out 状态；函数内部 tvu_irl_bytes_clear(out)
 *   - 写完后 m->header.length = out->length（保持 chunk 头长度字段同步）
 */

#include "tvu_irl_messages.h"

#include <stdlib.h>
#include <string.h>

/* ============================== Ack ============================== */

void tvu_irl_ack_init(tvu_irl_ack_message_t *m) {
    memset(m, 0, sizeof(*m));
    m->header.type = TVU_IRL_MSG_ACK;
}

void tvu_irl_ack_init_with_sequence(tvu_irl_ack_message_t *m, uint32_t sequence) {
    tvu_irl_ack_init(m);
    m->sequence = sequence;
}

void tvu_irl_ack_build_encoded(tvu_irl_ack_message_t *m, tvu_irl_bytes_t *out) {
    tvu_irl_bytes_clear(out);
    tvu_irl_bytes_append_be32(out, m->sequence);
    m->header.length = (int64_t)out->length;
}

bool tvu_irl_ack_parse(tvu_irl_ack_message_t *m, const uint8_t *data, size_t length) {
    if (length < 4) return false;
    m->sequence = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16)
                | ((uint32_t)data[2] << 8)  | (uint32_t)data[3];
    return true;
}

/* ============================== WindowAck ============================== */

void tvu_irl_window_ack_init(tvu_irl_window_ack_message_t *m) {
    memset(m, 0, sizeof(*m));
    m->header.type = TVU_IRL_MSG_WINDOW_ACK;
}

void tvu_irl_window_ack_init_with_size(tvu_irl_window_ack_message_t *m, uint32_t size) {
    tvu_irl_window_ack_init(m);
    m->size = size;
}

void tvu_irl_window_ack_build_encoded(tvu_irl_window_ack_message_t *m, tvu_irl_bytes_t *out) {
    tvu_irl_bytes_clear(out);
    tvu_irl_bytes_append_be32(out, m->size);
    m->header.length = (int64_t)out->length;
}

bool tvu_irl_window_ack_parse(tvu_irl_window_ack_message_t *m, const uint8_t *data, size_t length) {
    if (length < 4) return false;
    m->size = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16)
            | ((uint32_t)data[2] << 8)  | (uint32_t)data[3];
    return true;
}

/* ============================== FlowControl / SetChunkSize ============================== */

void tvu_irl_flow_control_init(tvu_irl_flow_control_t *m) {
    memset(m, 0, sizeof(*m));
    m->header.type = TVU_IRL_MSG_CHUNK_SIZE;
}

void tvu_irl_flow_control_init_with_size(tvu_irl_flow_control_t *m, uint32_t size) {
    tvu_irl_flow_control_init(m);
    m->size = size;
}

void tvu_irl_flow_control_build_encoded(tvu_irl_flow_control_t *m, tvu_irl_bytes_t *out) {
    tvu_irl_bytes_clear(out);
    tvu_irl_bytes_append_be32(out, m->size);
    m->header.length = (int64_t)out->length;
}

bool tvu_irl_flow_control_parse(tvu_irl_flow_control_t *m, const uint8_t *data, size_t length) {
    if (length < 4) return false;
    m->size = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16)
            | ((uint32_t)data[2] << 8)  | (uint32_t)data[3];
    return true;
}

/* ============================== BandwidthConfig ============================== */

void tvu_irl_bandwidth_config_init(tvu_irl_bandwidth_config_t *m) {
    memset(m, 0, sizeof(*m));
    m->header.type = TVU_IRL_MSG_BANDWIDTH;
    m->limit = TVU_IRL_BW_LIMIT_HARD;
}

void tvu_irl_bandwidth_config_init_with(tvu_irl_bandwidth_config_t *m,
                                        uint32_t size,
                                        tvu_irl_bandwidth_limit_t limit) {
    tvu_irl_bandwidth_config_init(m);
    m->size = size;
    m->limit = limit;
}

void tvu_irl_bandwidth_config_build_encoded(tvu_irl_bandwidth_config_t *m, tvu_irl_bytes_t *out) {
    tvu_irl_bytes_clear(out);
    tvu_irl_bytes_append_be32(out, m->size);
    tvu_irl_bytes_append_u8(out, (uint8_t)m->limit);
    m->header.length = (int64_t)out->length;
}

bool tvu_irl_bandwidth_config_parse(tvu_irl_bandwidth_config_t *m, const uint8_t *data, size_t length) {
    if (length < 5) return false;
    m->size = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16)
            | ((uint32_t)data[2] << 8)  | (uint32_t)data[3];
    switch (data[4]) {
        case TVU_IRL_BW_LIMIT_HARD:
        case TVU_IRL_BW_LIMIT_SOFT:
        case TVU_IRL_BW_LIMIT_DYNAMIC:
            m->limit = (tvu_irl_bandwidth_limit_t)data[4]; break;
        default:
            m->limit = TVU_IRL_BW_LIMIT_UNKNOWN; break;
    }
    return true;
}

/* ============================== CommandMessage ============================== */

void tvu_irl_command_message_init(tvu_irl_command_message_t *m,
                                  tvu_irl_message_type_t type,
                                  uint32_t stream_id) {
    memset(m, 0, sizeof(*m));
    m->header.type = type;
    m->header.stream_id = stream_id;
    tvu_irl_str_init(&m->command_name);
    tvu_irl_str_init_with_view(&m->command_name, TVU_IRL_CMD_CLOSE);
}

void tvu_irl_command_message_destroy(tvu_irl_command_message_t *m) {
    tvu_irl_str_destroy(&m->command_name);
    tvu_irl_amf_destroy(m->command_object);
    m->command_object = NULL;
    for (size_t i = 0; i < m->num_arguments; i++) {
        tvu_irl_amf_destroy(m->arguments[i]);
    }
    free(m->arguments);
    m->arguments = NULL;
    m->num_arguments = 0;
    m->arguments_capacity = 0;
}

void tvu_irl_command_message_set_name(tvu_irl_command_message_t *m, tvu_irl_strv_t name) {
    tvu_irl_str_set(&m->command_name, name);
}

void tvu_irl_command_message_set_object(tvu_irl_command_message_t *m,
                                        tvu_irl_amf_value_t *command_object) {
    if (m->command_object == command_object) return;   /* 防自赋值导致悬空 */
    tvu_irl_amf_destroy(m->command_object);
    m->command_object = command_object;
}

static void args_grow(tvu_irl_command_message_t *m, size_t min_cap) {
    if (m->arguments_capacity >= min_cap) return;
    size_t new_cap = m->arguments_capacity ? m->arguments_capacity : 2;
    while (new_cap < min_cap) new_cap <<= 1;
    tvu_irl_amf_value_t **p = (tvu_irl_amf_value_t **)realloc(m->arguments, new_cap * sizeof(*p));
    if (!p) abort();
    m->arguments = p;
    m->arguments_capacity = new_cap;
}

void tvu_irl_command_message_add_argument(tvu_irl_command_message_t *m,
                                          tvu_irl_amf_value_t *argument) {
    args_grow(m, m->num_arguments + 1);
    m->arguments[m->num_arguments++] = argument;
}

void tvu_irl_command_message_build_encoded(tvu_irl_command_message_t *m, tvu_irl_bytes_t *out) {
    tvu_irl_bytes_clear(out);
    /* AMF3 command 前置一个 0 字节作为 AMF0→AMF3 切换标记 */
    if (m->header.type == TVU_IRL_MSG_AMF3_COMMAND) {
        tvu_irl_bytes_append_u8(out, 0);
    }
    /* commandName (string) */
    tvu_irl_amf_value_t *name_val = tvu_irl_amf_new_string(tvu_irl_str_view(&m->command_name));
    tvu_irl_amf_encode(out, name_val);
    tvu_irl_amf_destroy(name_val);
    /* transactionId (number) */
    tvu_irl_amf_value_t *tid_val = tvu_irl_amf_new_number((double)m->transaction_id);
    tvu_irl_amf_encode(out, tid_val);
    tvu_irl_amf_destroy(tid_val);
    /* commandObject 或 null */
    if (m->command_object) {
        tvu_irl_amf_encode(out, m->command_object);
    } else {
        tvu_irl_amf_value_t *null_val = tvu_irl_amf_new_null();
        tvu_irl_amf_encode(out, null_val);
        tvu_irl_amf_destroy(null_val);
    }
    /* arguments */
    for (size_t i = 0; i < m->num_arguments; i++) {
        tvu_irl_amf_encode(out, m->arguments[i]);
    }
    m->header.length = (int64_t)out->length;
}

bool tvu_irl_command_message_parse(tvu_irl_command_message_t *m,
                                   const uint8_t *data, size_t length) {
    tvu_irl_reader_t r;
    tvu_irl_reader_init(&r, data, length);
    /* AMF3 跳过前置标记字节 */
    if (m->header.type == TVU_IRL_MSG_AMF3_COMMAND) {
        if (!tvu_irl_reader_skip(&r, 1)) return false;
    }
    /* commandName */
    tvu_irl_amf_value_t *name_val = tvu_irl_amf_decode(&r);
    if (!name_val) return false;
    if (name_val->type == TVU_IRL_AMF_STRING) {
        tvu_irl_str_set(&m->command_name, tvu_irl_str_view(&name_val->str));
    } else {
        tvu_irl_str_set(&m->command_name, TVU_IRL_CMD_UNKNOWN);
    }
    tvu_irl_amf_destroy(name_val);
    /* transactionId */
    tvu_irl_amf_value_t *tid_val = tvu_irl_amf_decode(&r);
    if (!tid_val) return false;
    if (tid_val->type == TVU_IRL_AMF_NUMBER) {
        m->transaction_id = (int64_t)tid_val->num;
    }
    tvu_irl_amf_destroy(tid_val);
    /* commandObject（可能为 null） */
    tvu_irl_amf_value_t *obj_val = tvu_irl_amf_decode(&r);
    if (!obj_val) return false;
    if (obj_val->type == TVU_IRL_AMF_NULL || obj_val->type == TVU_IRL_AMF_UNDEFINED) {
        tvu_irl_amf_destroy(obj_val);
        m->command_object = NULL;
    } else {
        m->command_object = obj_val;
    }
    /* 剩余作为 arguments */
    while (tvu_irl_reader_available(&r) > 0) {
        tvu_irl_amf_value_t *arg = tvu_irl_amf_decode(&r);
        if (!arg) break;
        tvu_irl_command_message_add_argument(m, arg);
    }
    return true;
}
