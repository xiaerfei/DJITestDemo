/*
 * tvu_irl_stream_config.h
 *
 * 替代 TVUIRLStreamProfile + TVUIRLStreamConfig。
 *
 * Profile：单条流的标识 + 延迟 + uuid。
 * Config：端口 + 多条 profile + noDelay。
 *
 * 内存模型：
 *   - Config 持有 streams 数组（owned 堆分配）
 *   - 每个 Profile 持有自己的 stream_key（owned tvu_irl_str_t）
 *   - 构造时深拷贝传入的 strv；destroy 时递归释放
 *   - 不允许跨 config 共享 profile（移动到 init_with 或新 add 会复制）
 *
 * 性能：
 *   - 实际部署 streams 数量为 1（RTMPIngestController 单流），数组分配走 small bin
 *   - find 使用线性查找，n=1 时无分支差异
 */

#ifndef TVU_IRL_STREAM_CONFIG_H
#define TVU_IRL_STREAM_CONFIG_H

#include "tvu_irl_str.h"

#include <stdint.h>
#include <stdbool.h>
#include <uuid/uuid.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    tvu_irl_str_t stream_key;
    int32_t       latency_ms;
    uuid_t        uuid;        /* unsigned char[16] */
} tvu_irl_stream_profile_t;

/* 构造：随机生成 uuid，深拷贝 stream_key。 */
void tvu_irl_stream_profile_init(tvu_irl_stream_profile_t *p,
                                 tvu_irl_strv_t stream_key,
                                 int32_t latency_ms);

/* 构造：使用指定 uuid（一般测试用）。 */
void tvu_irl_stream_profile_init_with_uuid(tvu_irl_stream_profile_t *p,
                                           tvu_irl_strv_t stream_key,
                                           int32_t latency_ms,
                                           const uuid_t uuid);

void tvu_irl_stream_profile_destroy(tvu_irl_stream_profile_t *p);

static inline double tvu_irl_stream_profile_latency_seconds(const tvu_irl_stream_profile_t *p) {
    return (double)p->latency_ms / 1000.0;
}

/* ---------- Config ---------- */

typedef struct {
    uint16_t                   port;
    bool                       no_delay;
    tvu_irl_stream_profile_t  *streams;       /* owned；num_streams == 0 时为 NULL */
    size_t                     num_streams;
    size_t                     streams_capacity;
} tvu_irl_stream_config_t;

/* 默认端口 1935，no_delay=true，无 streams。 */
void tvu_irl_stream_config_init(tvu_irl_stream_config_t *c);

void tvu_irl_stream_config_init_with(tvu_irl_stream_config_t *c,
                                     uint16_t port,
                                     bool no_delay);

void tvu_irl_stream_config_destroy(tvu_irl_stream_config_t *c);

/* 追加一条流。stream_key 内部深拷贝，uuid 随机生成。 */
void tvu_irl_stream_config_add_stream(tvu_irl_stream_config_t *c,
                                      tvu_irl_strv_t stream_key,
                                      int32_t latency_ms);

/* 按 stream_key 查找；未命中返回 NULL。 */
const tvu_irl_stream_profile_t *
tvu_irl_stream_config_find(const tvu_irl_stream_config_t *c, tvu_irl_strv_t stream_key);

/* 深拷贝（用于跨实例 snapshot）。dst 必须未 init 或刚 destroy。 */
void tvu_irl_stream_config_clone(tvu_irl_stream_config_t *dst,
                                 const tvu_irl_stream_config_t *src);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_STREAM_CONFIG_H */
