/*
 * tvu_irl_media_pipeline.h
 *
 * 替代 TVUIRLMediaPipeline。单 chunk_stream_id 的消息处理管道。
 *
 * 暴露字段供 connection 的 chunk parser 直接读写（消息头三个字段）；
 * 内部维护 messageBody raw buffer（Plan 11，替代 NSMutableData）。
 *
 * 创建时 alloc 4KB；增长上限 2MB（超过即触发 connection stop）。
 */

#ifndef TVU_IRL_MEDIA_PIPELINE_H
#define TVU_IRL_MEDIA_PIPELINE_H

#include "tvu_irl_stream_connection.h"

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

tvu_irl_media_pipeline_t *tvu_irl_media_pipeline_create(
    tvu_irl_stream_connection_t *connection, uint16_t chunk_stream_id);

void tvu_irl_media_pipeline_destroy(tvu_irl_media_pipeline_t *p);
void tvu_irl_media_pipeline_stop(tvu_irl_media_pipeline_t *p);

/* chunk parser 用：直接读/写消息头字段。 */
uint8_t  tvu_irl_media_pipeline_message_type_id(const tvu_irl_media_pipeline_t *p);
int64_t  tvu_irl_media_pipeline_message_length(const tvu_irl_media_pipeline_t *p);
uint32_t tvu_irl_media_pipeline_message_timestamp(const tvu_irl_media_pipeline_t *p);
bool     tvu_irl_media_pipeline_extended_timestamp_present_in_type3(const tvu_irl_media_pipeline_t *p);

void tvu_irl_media_pipeline_set_message_type_id(tvu_irl_media_pipeline_t *p, uint8_t v);
void tvu_irl_media_pipeline_set_message_length(tvu_irl_media_pipeline_t *p, int64_t v);
void tvu_irl_media_pipeline_set_message_timestamp(tvu_irl_media_pipeline_t *p, uint32_t v);
void tvu_irl_media_pipeline_set_message_stream_id(tvu_irl_media_pipeline_t *p, uint32_t v);
void tvu_irl_media_pipeline_set_is_absolute_timestamp(tvu_irl_media_pipeline_t *p, bool v);
void tvu_irl_media_pipeline_set_extended_timestamp_present_in_type3(tvu_irl_media_pipeline_t *p, bool v);

/* 当前消息还需多少字节。 */
int64_t tvu_irl_media_pipeline_remaining_bytes(const tvu_irl_media_pipeline_t *p);
/* 下一 chunk data 长度（min(chunkSizeFromClient, remaining)）。 */
int64_t tvu_irl_media_pipeline_next_chunk_data_size(const tvu_irl_media_pipeline_t *p);

/* 把 chunk 字节追加到 messageBody；满消息时触发 process_message。 */
void tvu_irl_media_pipeline_append_chunk_bytes(tvu_irl_media_pipeline_t *p,
                                               const uint8_t *bytes, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_MEDIA_PIPELINE_H */
