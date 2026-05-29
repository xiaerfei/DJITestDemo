/*
 * tvu_irl_media_packet.c
 */

#include "tvu_irl_media_packet.h"

#define MAX_TIMESTAMP_24BIT 0xFFFFFFu

/* 写 basic header（1-3 字节，取决于 chunk_stream_id 范围）。 */
static void write_basic_header(tvu_irl_bytes_t *out, tvu_irl_packet_type_t type, uint16_t csid) {
    uint8_t fmt = (uint8_t)type;
    if (csid <= 63) {
        tvu_irl_bytes_append_u8(out, (uint8_t)((fmt << 6) | (uint8_t)csid));
    } else if (csid <= 319) {
        uint8_t b[2] = { (uint8_t)((fmt << 6) | 0x00), (uint8_t)(csid - 64) };
        tvu_irl_bytes_append(out, b, 2);
    } else {
        uint16_t v = (uint16_t)(csid - 64);
        uint8_t b[3] = { (uint8_t)((fmt << 6) | 0x01),
                         (uint8_t)((v >> 8) & 0xFF),
                         (uint8_t)(v & 0xFF) };
        tvu_irl_bytes_append(out, b, 3);
    }
}

/* type 0/1/2 的消息头大小（不含 extended timestamp）。 */
static size_t message_header_size(tvu_irl_packet_type_t type) {
    switch (type) {
        case TVU_IRL_PACKET_TYPE_ZERO:  return 11;
        case TVU_IRL_PACKET_TYPE_ONE:   return 7;
        case TVU_IRL_PACKET_TYPE_TWO:   return 3;
        case TVU_IRL_PACKET_TYPE_THREE: return 0;
    }
    return 0;
}

void tvu_irl_media_packet_emit(
    tvu_irl_packet_type_t   type,
    uint16_t                chunk_stream_id,
    tvu_irl_message_type_t  message_type,
    uint32_t                message_stream_id,
    uint32_t                message_timestamp,
    const uint8_t          *body,
    size_t                  body_length,
    size_t                  max_chunk_size,
    tvu_irl_bytes_t        *out)
{
    tvu_irl_bytes_clear(out);

    /* 预留容量：粗略估计 body + 16 字节头 + (body/max_chunk_size) * 4 字节续接头 */
    if (max_chunk_size > 0) {
        size_t worst_case = body_length + 16
                         + ((body_length / max_chunk_size) + 1) * 4;
        tvu_irl_bytes_reserve(out, worst_case);
    }

    bool ext_ts = (message_timestamp > MAX_TIMESTAMP_24BIT);

    /* ===== 第一块：basic + msg header（+ ext_ts） + body 前缀 ===== */
    write_basic_header(out, type, chunk_stream_id);

    /* timestamp 24bit；若超出则写 0xFFFFFF 占位，真实值放 extended timestamp */
    tvu_irl_bytes_append_be24(out, ext_ts ? MAX_TIMESTAMP_24BIT : message_timestamp);

    if (type == TVU_IRL_PACKET_TYPE_ZERO || type == TVU_IRL_PACKET_TYPE_ONE) {
        /* message length (3 bytes BE) + message type (1 byte) */
        tvu_irl_bytes_append_be24(out, (uint32_t)body_length);
        tvu_irl_bytes_append_u8(out, (uint8_t)message_type);
    }
    if (type == TVU_IRL_PACKET_TYPE_ZERO) {
        /* message stream id (4 bytes LE) */
        tvu_irl_bytes_append_le32(out, message_stream_id);
    }
    if (ext_ts) {
        tvu_irl_bytes_append_be32(out, message_timestamp);
    }

    /* body 第一段 */
    if (max_chunk_size == 0 || body_length <= max_chunk_size) {
        tvu_irl_bytes_append(out, body, body_length);
        return;
    }
    tvu_irl_bytes_append(out, body, max_chunk_size);

    /* ===== 后续块：type-3 basic header + body 后续段 ===== */
    /* 保留 ObjC 行为：type-3 chunk 不重复 extended timestamp（DJI 不会触发，
     * 严格遵守 RTMP 1.0 spec 可改成每块都带，但当前 receiver 实现也未必处理） */
    (void)message_header_size;   /* 仅保留接口；当前实现内联了大小计算 */
    for (size_t pos = max_chunk_size; pos < body_length; pos += max_chunk_size) {
        write_basic_header(out, TVU_IRL_PACKET_TYPE_THREE, chunk_stream_id);
        size_t remain = body_length - pos;
        size_t this_chunk = remain < max_chunk_size ? remain : max_chunk_size;
        tvu_irl_bytes_append(out, body + pos, this_chunk);
    }
}
