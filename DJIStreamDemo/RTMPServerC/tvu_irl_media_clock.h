/*
 * tvu_irl_media_clock.h
 *
 * 替代 TVUIRLMediaClock。音视频延迟同步：根据最新音/视频 PTS 估算二者偏差，
 * 当偏差变化 > 100ms 时返回 update 决策，否则不动作。
 *
 * 全 POD，栈分配，无 heap，无生命周期负担。
 */

#ifndef TVU_IRL_MEDIA_CLOCK_H
#define TVU_IRL_MEDIA_CLOCK_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double audio_target_latency;
    double video_target_latency;
    bool   has_update;
} tvu_irl_media_clock_decision_t;

typedef struct {
    double target_latency;
    double latest_audio_pts;
    double latest_video_pts;
    bool   has_audio_pts;
    bool   has_video_pts;
    double current_av_diff;          /* INFINITY 表示尚未稳定 */
    double estimated_av_diff;
} tvu_irl_media_clock_t;

void tvu_irl_media_clock_init(tvu_irl_media_clock_t *c, double target_latency);

static inline void tvu_irl_media_clock_set_audio_pts(tvu_irl_media_clock_t *c, double pts) {
    c->latest_audio_pts = pts;
    c->has_audio_pts = true;
}

static inline void tvu_irl_media_clock_set_video_pts(tvu_irl_media_clock_t *c, double pts) {
    c->latest_video_pts = pts;
    c->has_video_pts = true;
}

tvu_irl_media_clock_decision_t tvu_irl_media_clock_update(tvu_irl_media_clock_t *c);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_MEDIA_CLOCK_H */
