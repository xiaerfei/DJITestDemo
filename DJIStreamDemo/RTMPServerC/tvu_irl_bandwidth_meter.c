/*
 * tvu_irl_bandwidth_meter.c
 */

#include "tvu_irl_bandwidth_meter.h"

tvu_irl_bandwidth_snapshot_t tvu_irl_bandwidth_meter_update(tvu_irl_bandwidth_meter_t *m) {
    uint64_t delta = m->total_bytes - m->previous_total_bytes;
    /* EMA-style 加权：k * 当前样本 + (100-k) * 历史 */
    m->latest_speed = (m->speed_change_rate * delta
                     + (100 - m->speed_change_rate) * m->latest_speed) / 100;
    m->previous_total_bytes = m->total_bytes;
    tvu_irl_bandwidth_snapshot_t s = { m->total_bytes, m->latest_speed };
    return s;
}
