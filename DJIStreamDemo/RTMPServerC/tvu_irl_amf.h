/*
 * tvu_irl_amf.h
 *
 * 替代 TVUIRLAmfValue / TVUIRLAmfEncoder / TVUIRLAmfDecoder。
 *
 * AmfValue 用 tagged union 实现，唯一所有者持有；object/array 递归拥有子节点。
 * 调用 _destroy 会自动递归释放 —— 不会泄漏，也不会双重释放（因为没有共享）。
 *
 * 对象 = 有序 KV 数组（ObjC 用 NSDictionary，AMF0 实际线序敏感；用数组才是协议
 * 正确的；命令对象 key 数量典型 < 10，线性查找无副作用）。
 *
 * 编码器接受任意 tvu_irl_bytes_t* 作为输出，不拥有；解码器接受 reader 视图，
 * 不拷贝底层数据 —— 命令解析路径上零分配（除了构造 amf_value 节点本身）。
 */

#ifndef TVU_IRL_AMF_H
#define TVU_IRL_AMF_H

#include "tvu_irl_bytes.h"
#include "tvu_irl_str.h"
#include "tvu_irl_io.h"

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    TVU_IRL_AMF_NUMBER       = 0,
    TVU_IRL_AMF_BOOL         = 1,
    TVU_IRL_AMF_STRING       = 2,
    TVU_IRL_AMF_OBJECT       = 3,
    TVU_IRL_AMF_NULL         = 4,
    TVU_IRL_AMF_UNDEFINED    = 5,
    TVU_IRL_AMF_REFERENCE    = 6,
    TVU_IRL_AMF_ECMA_ARRAY   = 7,
    TVU_IRL_AMF_STRICT_ARRAY = 8,
    TVU_IRL_AMF_DATE         = 9,
    TVU_IRL_AMF_UNSUPPORTED  = 10,
    TVU_IRL_AMF_XML_DOCUMENT = 11,
    TVU_IRL_AMF_TYPED_OBJECT = 12,
    TVU_IRL_AMF_AVMPLUSH     = 13,
} tvu_irl_amf_type_t;

typedef struct tvu_irl_amf_value tvu_irl_amf_value_t;

/* 对象：有序 KV 数组。key owned，value owned。 */
typedef struct {
    tvu_irl_str_t        key;
    tvu_irl_amf_value_t *value;
} tvu_irl_amf_kv_t;

typedef struct {
    tvu_irl_amf_kv_t *items;     /* owned；count==0 时 NULL */
    size_t            count;
    size_t            capacity;
} tvu_irl_amf_object_t;

/* 严格数组：amf_value 指针数组，元素 owned。 */
typedef struct {
    tvu_irl_amf_value_t **items;
    size_t                count;
    size_t                capacity;
} tvu_irl_amf_array_t;

struct tvu_irl_amf_value {
    tvu_irl_amf_type_t type;
    union {
        double                num;
        bool                  b;
        tvu_irl_str_t         str;          /* string / xml_document */
        tvu_irl_amf_object_t  obj;          /* object / ecma_array */
        tvu_irl_amf_array_t   arr;
        double                date_ms;      /* milliseconds since 1970 */
        struct {
            tvu_irl_str_t        type_name;
            tvu_irl_amf_object_t fields;
        } typed_obj;
    };
};

/* ---------- 构造（堆分配） ---------- */

tvu_irl_amf_value_t *tvu_irl_amf_new_number(double v);
tvu_irl_amf_value_t *tvu_irl_amf_new_bool(bool v);
tvu_irl_amf_value_t *tvu_irl_amf_new_string(tvu_irl_strv_t v);     /* 深拷贝 */
tvu_irl_amf_value_t *tvu_irl_amf_new_xml_document(tvu_irl_strv_t v);
tvu_irl_amf_value_t *tvu_irl_amf_new_object(void);                  /* 空 object */
tvu_irl_amf_value_t *tvu_irl_amf_new_ecma_array(void);
tvu_irl_amf_value_t *tvu_irl_amf_new_strict_array(void);
tvu_irl_amf_value_t *tvu_irl_amf_new_null(void);
tvu_irl_amf_value_t *tvu_irl_amf_new_undefined(void);
tvu_irl_amf_value_t *tvu_irl_amf_new_reference(void);
tvu_irl_amf_value_t *tvu_irl_amf_new_unsupported(void);
tvu_irl_amf_value_t *tvu_irl_amf_new_avmplush(void);
tvu_irl_amf_value_t *tvu_irl_amf_new_date(double ms_since_1970);
tvu_irl_amf_value_t *tvu_irl_amf_new_typed_object(tvu_irl_strv_t type_name);

/* 递归释放。NULL 安全。 */
void tvu_irl_amf_destroy(tvu_irl_amf_value_t *v);

/* ---------- object 操作 ---------- */

/* 追加 kv：key 深拷贝，value 所有权转移给 obj（caller 之后不应再 destroy value）。 */
void tvu_irl_amf_object_set(tvu_irl_amf_value_t *obj,
                            tvu_irl_strv_t key,
                            tvu_irl_amf_value_t *value);

/* 按 key 查找；未命中或非 object 类型返回 NULL。 */
const tvu_irl_amf_value_t *tvu_irl_amf_object_get(const tvu_irl_amf_value_t *obj,
                                                  tvu_irl_strv_t key);

static inline size_t tvu_irl_amf_object_count(const tvu_irl_amf_value_t *obj) {
    return (obj && (obj->type == TVU_IRL_AMF_OBJECT || obj->type == TVU_IRL_AMF_ECMA_ARRAY))
        ? obj->obj.count : 0;
}

/* ---------- strict_array 操作 ---------- */

void tvu_irl_amf_array_append(tvu_irl_amf_value_t *arr, tvu_irl_amf_value_t *value);

static inline size_t tvu_irl_amf_array_count(const tvu_irl_amf_value_t *arr) {
    return (arr && arr->type == TVU_IRL_AMF_STRICT_ARRAY) ? arr->arr.count : 0;
}

static inline const tvu_irl_amf_value_t *
tvu_irl_amf_array_get(const tvu_irl_amf_value_t *arr, size_t i) {
    return (arr && arr->type == TVU_IRL_AMF_STRICT_ARRAY && i < arr->arr.count)
        ? arr->arr.items[i] : NULL;
}

/* ---------- 类型化访问器（type mismatch 时返回默认值） ---------- */

static inline double tvu_irl_amf_get_number(const tvu_irl_amf_value_t *v) {
    return (v && v->type == TVU_IRL_AMF_NUMBER) ? v->num : 0.0;
}

static inline bool tvu_irl_amf_get_bool(const tvu_irl_amf_value_t *v) {
    return (v && v->type == TVU_IRL_AMF_BOOL) ? v->b : false;
}

static inline tvu_irl_strv_t tvu_irl_amf_get_string(const tvu_irl_amf_value_t *v) {
    if (v && (v->type == TVU_IRL_AMF_STRING || v->type == TVU_IRL_AMF_XML_DOCUMENT)) {
        return tvu_irl_str_view(&v->str);
    }
    return TVU_IRL_STRV_EMPTY;
}

/* ---------- 编码 / 解码 ---------- */

/* 把 v 编码追加到 out。out 由 caller 拥有；不修改 out 已有内容。 */
void tvu_irl_amf_encode(tvu_irl_bytes_t *out, const tvu_irl_amf_value_t *v);

/* 解码下一个 AMF0 值。失败返回 NULL，reader position 不保证恢复。 */
tvu_irl_amf_value_t *tvu_irl_amf_decode(tvu_irl_reader_t *r);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_AMF_H */
