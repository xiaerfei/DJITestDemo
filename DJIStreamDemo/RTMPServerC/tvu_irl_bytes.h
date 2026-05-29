/*
 * tvu_irl_bytes.h
 *
 * 替代 NSData / NSMutableData。独占所有权（unique ownership），无引用计数。
 * 共享场景请显式 clone。设计目标：
 *   - 零运行时开销的所有权转移（move 语义）
 *   - 栈上或嵌入式分配（struct 本身在父结构体中，仅 heap 一次给 data）
 *   - 几何增长 + 显式 reserve 控制 realloc 频次
 *   - 所有 init_* 严格对应 destroy；move 后 src 自动重置为空，杜绝双释放
 *
 * 不变量：
 *   - data == NULL  ⇔  capacity == 0  ⇔  length == 0
 *   - length <= capacity
 *   - 空状态合法：destroy 空状态是 no-op，append 到空状态会分配
 */

#ifndef TVU_IRL_BYTES_H
#define TVU_IRL_BYTES_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;       /* malloc'd; NULL 当且仅当 capacity==0 */
    size_t   length;
    size_t   capacity;
} tvu_irl_bytes_t;

/* ---------- 生命周期 ---------- */

/* 零初始化。栈分配后建议先调用以保证状态合法。 */
static inline void tvu_irl_bytes_init(tvu_irl_bytes_t *b) {
    b->data = NULL; b->length = 0; b->capacity = 0;
}

/* 预分配指定容量，length 仍为 0。cap=0 等价于 init。 */
void tvu_irl_bytes_init_with_capacity(tvu_irl_bytes_t *b, size_t cap);

/* 拷贝构造：从 src 复制 len 字节，length=cap=len。 */
void tvu_irl_bytes_init_with_copy(tvu_irl_bytes_t *b, const void *src, size_t len);

/* 释放 data 并重置为空状态。可重复调用。 */
void tvu_irl_bytes_destroy(tvu_irl_bytes_t *b);

/* ---------- 所有权 ---------- */

/* 把 src 的存储转交给 dst（src 必须为空 / 调用前 dst 内容会被覆盖且不释放，
 * 调用者保证 dst 当前为空或已 destroy）。src 在调用后重置为空。
 *
 * 用法：
 *     tvu_irl_bytes_t out; tvu_irl_bytes_init(&out);
 *     ... build into local ...
 *     tvu_irl_bytes_move(&out, &local);   // local 现在为空
 */
static inline void tvu_irl_bytes_move(tvu_irl_bytes_t *dst, tvu_irl_bytes_t *src) {
    dst->data = src->data;
    dst->length = src->length;
    dst->capacity = src->capacity;
    src->data = NULL; src->length = 0; src->capacity = 0;
}

/* 深拷贝。dst 必须为空（未 init 或刚 destroy）。 */
void tvu_irl_bytes_clone(tvu_irl_bytes_t *dst, const tvu_irl_bytes_t *src);

/* 把所有权转出为裸指针。返回 malloc'd 内存的所有权给调用者，
 * b 重置为空。out_length 不能为 NULL。返回 NULL 当且仅当 b 为空。
 * 调用者用完后必须 free()。 */
uint8_t *tvu_irl_bytes_take(tvu_irl_bytes_t *b, size_t *out_length);

/* ---------- 容量管理 ---------- */

/* 确保 capacity >= min_cap。可能 realloc。length 不变。 */
void tvu_irl_bytes_reserve(tvu_irl_bytes_t *b, size_t min_cap);

/* 设置 length；如 new_len > capacity 会 reserve。新增字节内容未定义。 */
void tvu_irl_bytes_set_length(tvu_irl_bytes_t *b, size_t new_len);

/* length=0，保留 capacity（便于复用）。 */
static inline void tvu_irl_bytes_clear(tvu_irl_bytes_t *b) { b->length = 0; }

/* ---------- 写入（追加） ---------- */

void tvu_irl_bytes_append(tvu_irl_bytes_t *b, const void *src, size_t len);

static inline void tvu_irl_bytes_append_u8(tvu_irl_bytes_t *b, uint8_t v) {
    if (b->length + 1 > b->capacity) tvu_irl_bytes_reserve(b, b->length + 1);
    b->data[b->length++] = v;
}

static inline void tvu_irl_bytes_append_be16(tvu_irl_bytes_t *b, uint16_t v) {
    if (b->length + 2 > b->capacity) tvu_irl_bytes_reserve(b, b->length + 2);
    b->data[b->length    ] = (uint8_t)(v >> 8);
    b->data[b->length + 1] = (uint8_t)(v);
    b->length += 2;
}

static inline void tvu_irl_bytes_append_be24(tvu_irl_bytes_t *b, uint32_t v) {
    if (b->length + 3 > b->capacity) tvu_irl_bytes_reserve(b, b->length + 3);
    b->data[b->length    ] = (uint8_t)(v >> 16);
    b->data[b->length + 1] = (uint8_t)(v >> 8);
    b->data[b->length + 2] = (uint8_t)(v);
    b->length += 3;
}

static inline void tvu_irl_bytes_append_be32(tvu_irl_bytes_t *b, uint32_t v) {
    if (b->length + 4 > b->capacity) tvu_irl_bytes_reserve(b, b->length + 4);
    b->data[b->length    ] = (uint8_t)(v >> 24);
    b->data[b->length + 1] = (uint8_t)(v >> 16);
    b->data[b->length + 2] = (uint8_t)(v >> 8);
    b->data[b->length + 3] = (uint8_t)(v);
    b->length += 4;
}

static inline void tvu_irl_bytes_append_le32(tvu_irl_bytes_t *b, uint32_t v) {
    if (b->length + 4 > b->capacity) tvu_irl_bytes_reserve(b, b->length + 4);
    b->data[b->length    ] = (uint8_t)(v);
    b->data[b->length + 1] = (uint8_t)(v >> 8);
    b->data[b->length + 2] = (uint8_t)(v >> 16);
    b->data[b->length + 3] = (uint8_t)(v >> 24);
    b->length += 4;
}

/* IEEE 754 double，big-endian（AMF0 Number 用）。 */
void tvu_irl_bytes_append_f64_be(tvu_irl_bytes_t *b, double v);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_BYTES_H */
