/*
 * tvu_irl_io.h
 *
 * 替代 TVUIRLDataReader.{h,m}。
 *
 * 设计目标：
 *   - 零拷贝读取：reader 只持有 (data ptr, length, position) 视图，不复制底层 buffer
 *   - 全内联：所有 read 函数 static inline，编译期消解到 1-3 条指令
 *   - 失败返回 false，输出参数原值保留（caller 可继续用上一个值或直接 abort）
 *   - 不区分 EOF / 格式错误：调用方只需"成功 / 失败"二元决策；如需精细错误，自行在
 *     调用点解释 r->position == r->length（EOF）vs 其他
 *
 * 不引入独立 writer 类型：tvu_irl_bytes_t 已经覆盖所有 append 场景。
 * 仅在此处补一个 strv → bytes 的 append 适配，避免 caller 写 .data/.length。
 */

#ifndef TVU_IRL_IO_H
#define TVU_IRL_IO_H

#include "tvu_irl_bytes.h"
#include "tvu_irl_str.h"

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================== Reader ============================== */

typedef struct {
    const uint8_t *data;     /* 非拥有视图；调用者保证 data 生命周期 >= reader */
    size_t         length;
    size_t         position;
} tvu_irl_reader_t;

static inline void tvu_irl_reader_init(tvu_irl_reader_t *r, const void *data, size_t length) {
    r->data = (const uint8_t *)data; r->length = length; r->position = 0;
}

static inline size_t tvu_irl_reader_available(const tvu_irl_reader_t *r) {
    return r->length - r->position;
}

static inline bool tvu_irl_reader_at_eof(const tvu_irl_reader_t *r) {
    return r->position >= r->length;
}

static inline bool tvu_irl_reader_read_u8(tvu_irl_reader_t *r, uint8_t *out) {
    if (r->position + 1 > r->length) return false;
    *out = r->data[r->position++];
    return true;
}

static inline bool tvu_irl_reader_read_be16(tvu_irl_reader_t *r, uint16_t *out) {
    if (r->position + 2 > r->length) return false;
    const uint8_t *p = r->data + r->position;
    *out = (uint16_t)((p[0] << 8) | p[1]);
    r->position += 2;
    return true;
}

static inline bool tvu_irl_reader_read_le16(tvu_irl_reader_t *r, uint16_t *out) {
    if (r->position + 2 > r->length) return false;
    const uint8_t *p = r->data + r->position;
    *out = (uint16_t)(p[0] | (p[1] << 8));
    r->position += 2;
    return true;
}

static inline bool tvu_irl_reader_read_be24(tvu_irl_reader_t *r, uint32_t *out) {
    if (r->position + 3 > r->length) return false;
    const uint8_t *p = r->data + r->position;
    *out = ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
    r->position += 3;
    return true;
}

static inline bool tvu_irl_reader_read_le24(tvu_irl_reader_t *r, uint32_t *out) {
    if (r->position + 3 > r->length) return false;
    const uint8_t *p = r->data + r->position;
    *out = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
    r->position += 3;
    return true;
}

static inline bool tvu_irl_reader_read_be32(tvu_irl_reader_t *r, uint32_t *out) {
    if (r->position + 4 > r->length) return false;
    const uint8_t *p = r->data + r->position;
    *out = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
    r->position += 4;
    return true;
}

static inline bool tvu_irl_reader_read_le32(tvu_irl_reader_t *r, uint32_t *out) {
    if (r->position + 4 > r->length) return false;
    const uint8_t *p = r->data + r->position;
    *out = (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    r->position += 4;
    return true;
}

static inline bool tvu_irl_reader_read_f64_be(tvu_irl_reader_t *r, double *out) {
    if (r->position + 8 > r->length) return false;
    const uint8_t *p = r->data + r->position;
    uint64_t u = ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48)
               | ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32)
               | ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16)
               | ((uint64_t)p[6] << 8)  | (uint64_t)p[7];
    memcpy(out, &u, 8);
    r->position += 8;
    return true;
}

/* 零拷贝读 N 字节，返回视图。view.data 寿命与 reader 底层 buffer 一致。 */
static inline bool tvu_irl_reader_read_view(tvu_irl_reader_t *r, tvu_irl_strv_t *out, size_t length) {
    if (r->position + length > r->length) return false;
    out->data = (const char *)(r->data + r->position);
    out->length = length;
    r->position += length;
    return true;
}

static inline bool tvu_irl_reader_skip(tvu_irl_reader_t *r, size_t length) {
    if (r->position + length > r->length) return false;
    r->position += length;
    return true;
}

/* ============================== Writer 适配 ============================== */

/* 把 strv 视图直接 append 到 bytes 缓冲。封装一行 memcpy，避免 caller 解构 strv。 */
static inline void tvu_irl_bytes_append_strv(tvu_irl_bytes_t *b, tvu_irl_strv_t v) {
    tvu_irl_bytes_append(b, v.data, v.length);
}

/* 有符号 32-bit 大端，便于代码可读（type cast 给编译器优化为同一指令）。 */
static inline void tvu_irl_bytes_append_be32_i32(tvu_irl_bytes_t *b, int32_t v) {
    tvu_irl_bytes_append_be32(b, (uint32_t)v);
}

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_IO_H */
