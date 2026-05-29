/*
 * tvu_irl_amf.c
 *
 * AMF0 编解码。设计要点：
 *   - 节点堆分配（calloc 零初始化所有 union 成员，析构路径不会访问到未初始化字段）
 *   - 复合类型（object / strict_array / typed_object）析构递归走子节点
 *   - decode 最大嵌套深度 16，防恶意输入栈溢出
 *   - 仅命令路径用，调用频率 ~1/connection lifecycle；不在 chunk 热路径
 */

#include "tvu_irl_amf.h"

#include <stdlib.h>
#include <string.h>

/* AMF0 marker。与 ObjC 版完全一致。 */
typedef enum {
    AMF0_MARKER_NUMBER        = 0x00,
    AMF0_MARKER_BOOL          = 0x01,
    AMF0_MARKER_STRING        = 0x02,
    AMF0_MARKER_OBJECT        = 0x03,
    AMF0_MARKER_NULL          = 0x05,
    AMF0_MARKER_UNDEFINED     = 0x06,
    AMF0_MARKER_REFERENCE     = 0x07,
    AMF0_MARKER_ECMA_ARRAY    = 0x08,
    AMF0_MARKER_OBJECT_END    = 0x09,
    AMF0_MARKER_STRICT_ARRAY  = 0x0A,
    AMF0_MARKER_DATE          = 0x0B,
    AMF0_MARKER_LONG_STRING   = 0x0C,
    AMF0_MARKER_UNSUPPORTED   = 0x0D,
    AMF0_MARKER_XML_DOCUMENT  = 0x0F,
    AMF0_MARKER_TYPED_OBJECT  = 0x10,
    AMF0_MARKER_AVMPLUSH      = 0x11,
} amf0_marker_t;

#define TVU_IRL_AMF_MAX_DEPTH 16
#define TVU_IRL_AMF_MAX_ARRAY_COUNT 128

/* ============================== 节点生命周期 ============================== */

static tvu_irl_amf_value_t *amf_alloc(tvu_irl_amf_type_t type) {
    tvu_irl_amf_value_t *v = (tvu_irl_amf_value_t *)calloc(1, sizeof(*v));
    if (!v) abort();
    v->type = type;
    return v;
}

static void object_destroy(tvu_irl_amf_object_t *o) {
    for (size_t i = 0; i < o->count; i++) {
        tvu_irl_str_destroy(&o->items[i].key);
        tvu_irl_amf_destroy(o->items[i].value);
    }
    free(o->items);
    o->items = NULL; o->count = 0; o->capacity = 0;
}

static void array_destroy(tvu_irl_amf_array_t *a) {
    for (size_t i = 0; i < a->count; i++) {
        tvu_irl_amf_destroy(a->items[i]);
    }
    free(a->items);
    a->items = NULL; a->count = 0; a->capacity = 0;
}

void tvu_irl_amf_destroy(tvu_irl_amf_value_t *v) {
    if (!v) return;
    switch (v->type) {
        case TVU_IRL_AMF_STRING:
        case TVU_IRL_AMF_XML_DOCUMENT:
            tvu_irl_str_destroy(&v->str);
            break;
        case TVU_IRL_AMF_OBJECT:
        case TVU_IRL_AMF_ECMA_ARRAY:
            object_destroy(&v->obj);
            break;
        case TVU_IRL_AMF_STRICT_ARRAY:
            array_destroy(&v->arr);
            break;
        case TVU_IRL_AMF_TYPED_OBJECT:
            tvu_irl_str_destroy(&v->typed_obj.type_name);
            object_destroy(&v->typed_obj.fields);
            break;
        default: break;  /* 标量 / 单例：calloc 零初始化即可全释放 */
    }
    free(v);
}

/* ============================== 构造 ============================== */

tvu_irl_amf_value_t *tvu_irl_amf_new_number(double v)   { tvu_irl_amf_value_t *r = amf_alloc(TVU_IRL_AMF_NUMBER); r->num = v; return r; }
tvu_irl_amf_value_t *tvu_irl_amf_new_bool(bool v)       { tvu_irl_amf_value_t *r = amf_alloc(TVU_IRL_AMF_BOOL);   r->b = v;   return r; }

tvu_irl_amf_value_t *tvu_irl_amf_new_string(tvu_irl_strv_t v) {
    tvu_irl_amf_value_t *r = amf_alloc(TVU_IRL_AMF_STRING);
    tvu_irl_str_init_with_view(&r->str, v);
    return r;
}

tvu_irl_amf_value_t *tvu_irl_amf_new_xml_document(tvu_irl_strv_t v) {
    tvu_irl_amf_value_t *r = amf_alloc(TVU_IRL_AMF_XML_DOCUMENT);
    tvu_irl_str_init_with_view(&r->str, v);
    return r;
}

tvu_irl_amf_value_t *tvu_irl_amf_new_object(void)        { return amf_alloc(TVU_IRL_AMF_OBJECT); }
tvu_irl_amf_value_t *tvu_irl_amf_new_ecma_array(void)    { return amf_alloc(TVU_IRL_AMF_ECMA_ARRAY); }
tvu_irl_amf_value_t *tvu_irl_amf_new_strict_array(void)  { return amf_alloc(TVU_IRL_AMF_STRICT_ARRAY); }
tvu_irl_amf_value_t *tvu_irl_amf_new_null(void)          { return amf_alloc(TVU_IRL_AMF_NULL); }
tvu_irl_amf_value_t *tvu_irl_amf_new_undefined(void)     { return amf_alloc(TVU_IRL_AMF_UNDEFINED); }
tvu_irl_amf_value_t *tvu_irl_amf_new_reference(void)     { return amf_alloc(TVU_IRL_AMF_REFERENCE); }
tvu_irl_amf_value_t *tvu_irl_amf_new_unsupported(void)   { return amf_alloc(TVU_IRL_AMF_UNSUPPORTED); }
tvu_irl_amf_value_t *tvu_irl_amf_new_avmplush(void)      { return amf_alloc(TVU_IRL_AMF_AVMPLUSH); }

tvu_irl_amf_value_t *tvu_irl_amf_new_date(double ms_since_1970) {
    tvu_irl_amf_value_t *r = amf_alloc(TVU_IRL_AMF_DATE);
    r->date_ms = ms_since_1970;
    return r;
}

tvu_irl_amf_value_t *tvu_irl_amf_new_typed_object(tvu_irl_strv_t type_name) {
    tvu_irl_amf_value_t *r = amf_alloc(TVU_IRL_AMF_TYPED_OBJECT);
    tvu_irl_str_init_with_view(&r->typed_obj.type_name, type_name);
    return r;
}

/* ============================== 容器操作 ============================== */

static void object_grow(tvu_irl_amf_object_t *o, size_t min_cap) {
    if (o->capacity >= min_cap) return;
    size_t new_cap = o->capacity ? o->capacity : 4;
    while (new_cap < min_cap) new_cap <<= 1;
    tvu_irl_amf_kv_t *p = (tvu_irl_amf_kv_t *)realloc(o->items, new_cap * sizeof(*p));
    if (!p) abort();
    o->items = p; o->capacity = new_cap;
}

static void object_push(tvu_irl_amf_object_t *o,
                        tvu_irl_strv_t key,
                        tvu_irl_amf_value_t *value) {
    object_grow(o, o->count + 1);
    tvu_irl_str_init_with_view(&o->items[o->count].key, key);
    o->items[o->count].value = value;
    o->count++;
}

void tvu_irl_amf_object_set(tvu_irl_amf_value_t *obj,
                            tvu_irl_strv_t key,
                            tvu_irl_amf_value_t *value) {
    if (!obj || (obj->type != TVU_IRL_AMF_OBJECT && obj->type != TVU_IRL_AMF_ECMA_ARRAY)) {
        tvu_irl_amf_destroy(value);  /* 避免泄漏 */
        return;
    }
    object_push(&obj->obj, key, value);
}

const tvu_irl_amf_value_t *tvu_irl_amf_object_get(const tvu_irl_amf_value_t *obj,
                                                  tvu_irl_strv_t key) {
    if (!obj || (obj->type != TVU_IRL_AMF_OBJECT && obj->type != TVU_IRL_AMF_ECMA_ARRAY)) return NULL;
    for (size_t i = 0; i < obj->obj.count; i++) {
        if (tvu_irl_strv_equals(tvu_irl_str_view(&obj->obj.items[i].key), key)) {
            return obj->obj.items[i].value;
        }
    }
    return NULL;
}

static void array_grow(tvu_irl_amf_array_t *a, size_t min_cap) {
    if (a->capacity >= min_cap) return;
    size_t new_cap = a->capacity ? a->capacity : 4;
    while (new_cap < min_cap) new_cap <<= 1;
    tvu_irl_amf_value_t **p = (tvu_irl_amf_value_t **)realloc(a->items, new_cap * sizeof(*p));
    if (!p) abort();
    a->items = p; a->capacity = new_cap;
}

void tvu_irl_amf_array_append(tvu_irl_amf_value_t *arr, tvu_irl_amf_value_t *value) {
    if (!arr || arr->type != TVU_IRL_AMF_STRICT_ARRAY) {
        tvu_irl_amf_destroy(value);
        return;
    }
    array_grow(&arr->arr, arr->arr.count + 1);
    arr->arr.items[arr->arr.count++] = value;
}

/* ============================== 编码 ============================== */

static void encode_short_string(tvu_irl_bytes_t *out, tvu_irl_strv_t v) {
    tvu_irl_bytes_append_be16(out, (uint16_t)v.length);
    tvu_irl_bytes_append_strv(out, v);
}

static void encode_long_string(tvu_irl_bytes_t *out, tvu_irl_strv_t v) {
    tvu_irl_bytes_append_be32(out, (uint32_t)v.length);
    tvu_irl_bytes_append_strv(out, v);
}

static void encode_string_value(tvu_irl_bytes_t *out, tvu_irl_strv_t v) {
    if (v.length > UINT16_MAX) {
        tvu_irl_bytes_append_u8(out, AMF0_MARKER_LONG_STRING);
        encode_long_string(out, v);
    } else {
        tvu_irl_bytes_append_u8(out, AMF0_MARKER_STRING);
        encode_short_string(out, v);
    }
}

static void encode_object_body(tvu_irl_bytes_t *out, const tvu_irl_amf_object_t *o) {
    for (size_t i = 0; i < o->count; i++) {
        encode_short_string(out, tvu_irl_str_view(&o->items[i].key));
        tvu_irl_amf_encode(out, o->items[i].value);
    }
    encode_short_string(out, TVU_IRL_STRV_EMPTY);
    tvu_irl_bytes_append_u8(out, AMF0_MARKER_OBJECT_END);
}

void tvu_irl_amf_encode(tvu_irl_bytes_t *out, const tvu_irl_amf_value_t *v) {
    if (!v) {
        tvu_irl_bytes_append_u8(out, AMF0_MARKER_NULL);
        return;
    }
    switch (v->type) {
        case TVU_IRL_AMF_NUMBER:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_NUMBER);
            tvu_irl_bytes_append_f64_be(out, v->num);
            break;
        case TVU_IRL_AMF_BOOL: {
            uint8_t buf[2] = { AMF0_MARKER_BOOL, v->b ? 0x01 : 0x00 };
            tvu_irl_bytes_append(out, buf, 2);
            break;
        }
        case TVU_IRL_AMF_STRING:
            encode_string_value(out, tvu_irl_str_view(&v->str));
            break;
        case TVU_IRL_AMF_OBJECT:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_OBJECT);
            encode_object_body(out, &v->obj);
            break;
        case TVU_IRL_AMF_NULL:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_NULL);
            break;
        case TVU_IRL_AMF_UNDEFINED:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_UNDEFINED);
            break;
        case TVU_IRL_AMF_REFERENCE:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_REFERENCE);
            break;
        case TVU_IRL_AMF_ECMA_ARRAY:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_ECMA_ARRAY);
            tvu_irl_bytes_append_be32(out, 0);   /* associative-count，AMF0 仅作提示 */
            encode_object_body(out, &v->obj);
            break;
        case TVU_IRL_AMF_STRICT_ARRAY:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_STRICT_ARRAY);
            tvu_irl_bytes_append_be32(out, (uint32_t)v->arr.count);
            for (size_t i = 0; i < v->arr.count; i++) {
                tvu_irl_amf_encode(out, v->arr.items[i]);
            }
            break;
        case TVU_IRL_AMF_DATE:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_DATE);
            tvu_irl_bytes_append_f64_be(out, v->date_ms);
            tvu_irl_bytes_append_be16(out, 0);   /* timezone，AMF0 保留 */
            break;
        case TVU_IRL_AMF_UNSUPPORTED:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_UNSUPPORTED);
            break;
        case TVU_IRL_AMF_XML_DOCUMENT:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_XML_DOCUMENT);
            encode_long_string(out, tvu_irl_str_view(&v->str));
            break;
        case TVU_IRL_AMF_TYPED_OBJECT:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_TYPED_OBJECT);
            encode_short_string(out, tvu_irl_str_view(&v->typed_obj.type_name));
            encode_object_body(out, &v->typed_obj.fields);
            break;
        case TVU_IRL_AMF_AVMPLUSH:
            tvu_irl_bytes_append_u8(out, AMF0_MARKER_AVMPLUSH);
            break;
    }
}

/* ============================== 解码 ============================== */

static tvu_irl_amf_value_t *decode_value(tvu_irl_reader_t *r, int depth);

static bool decode_short_string(tvu_irl_reader_t *r, tvu_irl_strv_t *out) {
    uint16_t length;
    if (!tvu_irl_reader_read_be16(r, &length)) return false;
    return tvu_irl_reader_read_view(r, out, length);
}

static bool decode_long_string(tvu_irl_reader_t *r, tvu_irl_strv_t *out) {
    uint32_t length;
    if (!tvu_irl_reader_read_be32(r, &length)) return false;
    return tvu_irl_reader_read_view(r, out, length);
}

/* 解析 object 体（直到 ObjectEnd marker）。失败时 obj 内部状态合法，
 * caller 仍需 destroy 包裹此 obj 的 amf_value。 */
static bool decode_object_body(tvu_irl_reader_t *r, tvu_irl_amf_object_t *obj, int depth) {
    if (depth > TVU_IRL_AMF_MAX_DEPTH) return false;
    for (;;) {
        tvu_irl_strv_t key;
        if (!decode_short_string(r, &key)) return false;
        if (key.length == 0) break;
        tvu_irl_amf_value_t *value = decode_value(r, depth + 1);
        if (!value) return false;
        object_push(obj, key, value);
    }
    uint8_t end;
    if (!tvu_irl_reader_read_u8(r, &end)) return false;
    return end == AMF0_MARKER_OBJECT_END;
}

static tvu_irl_amf_value_t *decode_value(tvu_irl_reader_t *r, int depth) {
    if (depth > TVU_IRL_AMF_MAX_DEPTH) return NULL;
    uint8_t marker;
    if (!tvu_irl_reader_read_u8(r, &marker)) return NULL;
    switch ((amf0_marker_t)marker) {
        case AMF0_MARKER_NUMBER: {
            double v;
            if (!tvu_irl_reader_read_f64_be(r, &v)) return NULL;
            return tvu_irl_amf_new_number(v);
        }
        case AMF0_MARKER_BOOL: {
            uint8_t b;
            if (!tvu_irl_reader_read_u8(r, &b)) return NULL;
            return tvu_irl_amf_new_bool(b == 0x01);
        }
        case AMF0_MARKER_STRING: {
            tvu_irl_strv_t s;
            if (!decode_short_string(r, &s)) return NULL;
            return tvu_irl_amf_new_string(s);
        }
        case AMF0_MARKER_OBJECT: {
            tvu_irl_amf_value_t *o = tvu_irl_amf_new_object();
            if (!decode_object_body(r, &o->obj, depth)) { tvu_irl_amf_destroy(o); return NULL; }
            return o;
        }
        case AMF0_MARKER_NULL:        return tvu_irl_amf_new_null();
        case AMF0_MARKER_UNDEFINED:   return tvu_irl_amf_new_undefined();
        case AMF0_MARKER_REFERENCE:   return tvu_irl_amf_new_reference();
        case AMF0_MARKER_ECMA_ARRAY: {
            uint32_t count;
            if (!tvu_irl_reader_read_be32(r, &count)) return NULL;
            if (count >= TVU_IRL_AMF_MAX_ARRAY_COUNT) return NULL;  /* 反恶意输入 */
            tvu_irl_amf_value_t *o = tvu_irl_amf_new_ecma_array();
            if (!decode_object_body(r, &o->obj, depth)) { tvu_irl_amf_destroy(o); return NULL; }
            return o;
        }
        case AMF0_MARKER_STRICT_ARRAY: {
            uint32_t count;
            if (!tvu_irl_reader_read_be32(r, &count)) return NULL;
            if (count >= TVU_IRL_AMF_MAX_ARRAY_COUNT) return NULL;
            tvu_irl_amf_value_t *a = tvu_irl_amf_new_strict_array();
            for (uint32_t i = 0; i < count; i++) {
                tvu_irl_amf_value_t *child = decode_value(r, depth + 1);
                if (!child) { tvu_irl_amf_destroy(a); return NULL; }
                tvu_irl_amf_array_append(a, child);
            }
            return a;
        }
        case AMF0_MARKER_DATE: {
            double ms;
            uint16_t tz;
            if (!tvu_irl_reader_read_f64_be(r, &ms)) return NULL;
            if (!tvu_irl_reader_read_be16(r, &tz))   return NULL;
            return tvu_irl_amf_new_date(ms);
        }
        case AMF0_MARKER_LONG_STRING: {
            tvu_irl_strv_t s;
            if (!decode_long_string(r, &s)) return NULL;
            return tvu_irl_amf_new_string(s);
        }
        case AMF0_MARKER_UNSUPPORTED: return tvu_irl_amf_new_unsupported();
        case AMF0_MARKER_XML_DOCUMENT: {
            tvu_irl_strv_t s;
            if (!decode_long_string(r, &s)) return NULL;
            return tvu_irl_amf_new_xml_document(s);
        }
        case AMF0_MARKER_TYPED_OBJECT: {
            tvu_irl_strv_t name;
            if (!decode_short_string(r, &name)) return NULL;
            tvu_irl_amf_value_t *o = tvu_irl_amf_new_typed_object(name);
            if (!decode_object_body(r, &o->typed_obj.fields, depth)) { tvu_irl_amf_destroy(o); return NULL; }
            return o;
        }
        case AMF0_MARKER_AVMPLUSH:    return tvu_irl_amf_new_avmplush();
        case AMF0_MARKER_OBJECT_END:
        default:
            return NULL;
    }
}

tvu_irl_amf_value_t *tvu_irl_amf_decode(tvu_irl_reader_t *r) {
    return decode_value(r, 0);
}
