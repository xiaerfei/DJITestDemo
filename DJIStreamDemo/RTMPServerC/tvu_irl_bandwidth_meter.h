/*
 * tvu_irl_bandwidth_meter.h
 *
 * 替代 TVUIRLBandwidthMeter。RTMP 输入码率统计：累计字节数 + 平滑后的瞬时速度。
 * 公式：latest = (k * delta + (100-k) * latest_prev) / 100，k 为 change_rate (默认 10)。
 *
 * 状态全是 plain old data，结构体值类型，无 heap 分配，无生命周期负担。
 */

#ifndef TVU_IRL_BANDWIDTH_METER_H
#define TVU_IRL_BANDWIDTH_METER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t total;
    uint64_t speed;       /* bytes/s，update 调用之间的滑动平均 */
} tvu_irl_bandwidth_snapshot_t;

typedef struct {
    uint64_t total_bytes;
    uint64_t latest_speed;
    uint64_t previous_total_bytes;
    uint64_t speed_change_rate;   /* 1..100；10 接近 EMA(α=0.1) */
} tvu_irl_bandwidth_meter_t;

static inline void tvu_irl_bandwidth_meter_init(tvu_irl_bandwidth_meter_t *m) {
    m->total_bytes = 0;
    m->latest_speed = 0;
    m->previous_total_bytes = 0;
    m->speed_change_rate = 10;
}

static inline void tvu_irl_bandwidth_meter_init_with_rate(tvu_irl_bandwidth_meter_t *m,
                                                          uint64_t change_rate) {
    m->total_bytes = 0;
    m->latest_speed = 0;
    m->previous_total_bytes = 0;
    m->speed_change_rate = change_rate;
}

static inline void tvu_irl_bandwidth_meter_add(tvu_irl_bandwidth_meter_t *m, size_t bytes) {
    m->total_bytes += (uint64_t)bytes;
}

/* 推进采样窗口；返回新的 snapshot。 */
tvu_irl_bandwidth_snapshot_t tvu_irl_bandwidth_meter_update(tvu_irl_bandwidth_meter_t *m);

/* 仅读当前快照，不推进窗口。 */
static inline tvu_irl_bandwidth_snapshot_t
tvu_irl_bandwidth_meter_snapshot(const tvu_irl_bandwidth_meter_t *m) {
    tvu_irl_bandwidth_snapshot_t s = { m->total_bytes, m->latest_speed };
    return s;
}

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_BANDWIDTH_METER_H */
