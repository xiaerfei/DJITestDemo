/*
 * tvu_irl_media_packet.h
 *
 * 替代 TVUIRLMediaPacket。RTMP chunk 编码 + 分块。
 *
 * 设计：无状态自由函数，一次调用产出完整字节流（含 basic header / msg header
 * / 可选 extended timestamp / body，body 超过 max_chunk_size 时自动用 type-3
 * basic header 续接）。caller 把 out 直接 write 给 transport，单次系统调用。
 *
 * 与 ObjC 版本相比：消除 NSArray<NSData*> 中间分块对象 + 每块独立 transport
 * 写入；改为单一连续 buffer，热路径少 1-N 次 alloc + N-1 次 socket write。
 */

#ifndef TVU_IRL_MEDIA_PACKET_H
#define TVU_IRL_MEDIA_PACKET_H

#include "tvu_irl_bytes.h"
#include "tvu_irl_messages.h"

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    TVU_IRL_PACKET_TYPE_ZERO  = 0,   /* 完整 11 字节消息头 */
    TVU_IRL_PACKET_TYPE_ONE   = 1,   /* 7 字节，同 stream 续传 */
    TVU_IRL_PACKET_TYPE_TWO   = 2,   /* 3 字节，仅时间戳增量 */
    TVU_IRL_PACKET_TYPE_THREE = 3,   /* 0 字节，复用上次 */
} tvu_irl_packet_type_t;

typedef enum {
    TVU_IRL_CSID_CONTROL = 0x02,
    TVU_IRL_CSID_COMMAND = 0x03,
    TVU_IRL_CSID_DATA    = 0x08,
} tvu_irl_chunk_stream_id_t;

/* 一次性编出完整 chunk 字节流（多块自动续接）。out 调用前不要求状态，
 * 函数内 clear 再 append。 */
void tvu_irl_media_packet_emit(
    tvu_irl_packet_type_t   type,
    uint16_t                chunk_stream_id,
    tvu_irl_message_type_t  message_type,
    uint32_t                message_stream_id,
    uint32_t                message_timestamp,
    const uint8_t          *body,
    size_t                  body_length,
    size_t                  max_chunk_size,
    tvu_irl_bytes_t        *out);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_MEDIA_PACKET_H */
