/*
 * tvu_irl_str.h
 *
 * 替代 NSString。两种类型：
 *
 *   tvu_irl_strv_t — 非拥有视图（const char* + length）。值类型，传参/返回零开销。
 *                    生命周期由底层 buffer 决定。不要存储跨越底层 buffer 生命周期。
 *
 *   tvu_irl_str_t — 拥有式（malloc + null-terminated + 缓存 length）。存储在
 *                   结构体字段中时使用。严格 init / destroy 配对。
 *
 * AMF 字符串、stream key、命令名、错误原因都使用 view 在内部传递，跨越生命
 * 周期边界（如存入 connection->stream_key）才转 owned。
 */

#ifndef TVU_IRL_STR_H
#define TVU_IRL_STR_H

#include <stddef.h>
#include <stdbool.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ===================== view ===================== */

typedef struct {
    const char *data;   /* 可能为 NULL；如果 length>0 则保证非 NULL */
    size_t      length;
} tvu_irl_strv_t;

#define TVU_IRL_STRV_LITERAL(lit) ((tvu_irl_strv_t){ (lit), sizeof(lit) - 1 })
#define TVU_IRL_STRV_EMPTY        ((tvu_irl_strv_t){ NULL, 0 })

static inline tvu_irl_strv_t tvu_irl_strv_from_cstr(const char *s) {
    return (tvu_irl_strv_t){ s, s ? strlen(s) : 0 };
}

static inline tvu_irl_strv_t tvu_irl_strv_make(const char *data, size_t length) {
    return (tvu_irl_strv_t){ data, length };
}

static inline bool tvu_irl_strv_is_empty(tvu_irl_strv_t v) { return v.length == 0; }

static inline bool tvu_irl_strv_equals(tvu_irl_strv_t a, tvu_irl_strv_t b) {
    return a.length == b.length && (a.length == 0 || memcmp(a.data, b.data, a.length) == 0);
}

/* 字面量优化：编译器会内联 strlen 为常量。 */
static inline bool tvu_irl_strv_equals_cstr(tvu_irl_strv_t a, const char *cstr) {
    size_t clen = strlen(cstr);
    return a.length == clen && (clen == 0 || memcmp(a.data, cstr, clen) == 0);
}

/* ===================== owned ===================== */

typedef struct {
    char  *data;        /* malloc'd, null-terminated; NULL 当且仅当 length==0 */
    size_t length;
} tvu_irl_str_t;

/* 零初始化为空字符串。 */
static inline void tvu_irl_str_init(tvu_irl_str_t *s) { s->data = NULL; s->length = 0; }

/* 从 C 字符串拷贝构造。cstr=NULL 等价空串。 */
void tvu_irl_str_init_with_cstr(tvu_irl_str_t *s, const char *cstr);

/* 从 view 拷贝构造。view.data 可不是 null-terminated，会自动加 0。 */
void tvu_irl_str_init_with_view(tvu_irl_str_t *s, tvu_irl_strv_t v);

/* 释放并重置为空。可重复调用。 */
void tvu_irl_str_destroy(tvu_irl_str_t *s);

/* 替换内容：释放原值并按 v 重新分配。 */
void tvu_irl_str_set(tvu_irl_str_t *s, tvu_irl_strv_t v);

/* 取所有权（zero-copy 转出）。s 重置为空，返回 malloc'd 指针。
 * 返回 NULL 当且仅当 s 为空。out_length 不能为 NULL。
 * 调用者用完后必须 free()。 */
char *tvu_irl_str_take(tvu_irl_str_t *s, size_t *out_length);

/* 转 view，仅借用。s 必须保活至 view 使用完毕。 */
static inline tvu_irl_strv_t tvu_irl_str_view(const tvu_irl_str_t *s) {
    return (tvu_irl_strv_t){ s->data, s->length };
}

/* 把 owned src move 给 dst（dst 必须为空或刚 destroy）。src 重置为空。 */
static inline void tvu_irl_str_move(tvu_irl_str_t *dst, tvu_irl_str_t *src) {
    dst->data = src->data; dst->length = src->length;
    src->data = NULL; src->length = 0;
}

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_STR_H */
