/*
 * tvu_irl_bytes.c
 *
 * 实现要点：
 *   - 增长策略：max(min_cap, capacity * 2)，doubling，amortized O(1) append
 *   - 所有失败路径（malloc/realloc 返回 NULL）通过 abort 终止 —— iOS app 进程
 *     范围内一旦内存分配失败基本不可恢复，提早 fail 比静默丢数据更安全
 *   - destroy 后状态合法，可重复调用
 */

#include "tvu_irl_bytes.h"

#include <stdlib.h>

/* ---------- 内部 ---------- */

static void tvu_irl_bytes_grow_to(tvu_irl_bytes_t *b, size_t min_cap) {
    size_t new_cap = b->capacity ? b->capacity : 16;
    while (new_cap < min_cap) {
        /* 防溢出：超过 SIZE_MAX/2 时直接 jump 到 min_cap */
        if (new_cap > (SIZE_MAX >> 1)) { new_cap = min_cap; break; }
        new_cap <<= 1;
    }
    uint8_t *p = (uint8_t *)realloc(b->data, new_cap);
    if (!p) abort();
    b->data = p;
    b->capacity = new_cap;
}

/* ---------- 生命周期 ---------- */

void tvu_irl_bytes_init_with_capacity(tvu_irl_bytes_t *b, size_t cap) {
    b->data = NULL; b->length = 0; b->capacity = 0;
    if (cap) tvu_irl_bytes_grow_to(b, cap);
}

void tvu_irl_bytes_init_with_copy(tvu_irl_bytes_t *b, const void *src, size_t len) {
    b->data = NULL; b->length = 0; b->capacity = 0;
    if (len == 0) return;
    tvu_irl_bytes_grow_to(b, len);
    memcpy(b->data, src, len);
    b->length = len;
}

void tvu_irl_bytes_destroy(tvu_irl_bytes_t *b) {
    free(b->data);
    b->data = NULL; b->length = 0; b->capacity = 0;
}

/* ---------- 所有权 ---------- */

void tvu_irl_bytes_clone(tvu_irl_bytes_t *dst, const tvu_irl_bytes_t *src) {
    dst->data = NULL; dst->length = 0; dst->capacity = 0;
    if (src->length == 0) return;
    tvu_irl_bytes_grow_to(dst, src->length);
    memcpy(dst->data, src->data, src->length);
    dst->length = src->length;
}

uint8_t *tvu_irl_bytes_take(tvu_irl_bytes_t *b, size_t *out_length) {
    uint8_t *p = b->data;
    *out_length = b->length;
    b->data = NULL; b->length = 0; b->capacity = 0;
    return p;
}

/* ---------- 容量管理 ---------- */

void tvu_irl_bytes_reserve(tvu_irl_bytes_t *b, size_t min_cap) {
    if (b->capacity >= min_cap) return;
    tvu_irl_bytes_grow_to(b, min_cap);
}

void tvu_irl_bytes_set_length(tvu_irl_bytes_t *b, size_t new_len) {
    if (new_len > b->capacity) tvu_irl_bytes_grow_to(b, new_len);
    b->length = new_len;
}

/* ---------- 写入 ---------- */

void tvu_irl_bytes_append(tvu_irl_bytes_t *b, const void *src, size_t len) {
    if (len == 0) return;
    if (b->length + len > b->capacity) tvu_irl_bytes_reserve(b, b->length + len);
    memcpy(b->data + b->length, src, len);
    b->length += len;
}

void tvu_irl_bytes_append_f64_be(tvu_irl_bytes_t *b, double v) {
    uint64_t u;
    memcpy(&u, &v, 8);  /* type-punning via memcpy: 编译器会优化为单条 MOV */
    if (b->length + 8 > b->capacity) tvu_irl_bytes_reserve(b, b->length + 8);
    uint8_t *p = b->data + b->length;
    p[0] = (uint8_t)(u >> 56);
    p[1] = (uint8_t)(u >> 48);
    p[2] = (uint8_t)(u >> 40);
    p[3] = (uint8_t)(u >> 32);
    p[4] = (uint8_t)(u >> 24);
    p[5] = (uint8_t)(u >> 16);
    p[6] = (uint8_t)(u >> 8);
    p[7] = (uint8_t)(u);
    b->length += 8;
}
