/*
 * tvu_irl_media_clock.c
 */

#include "tvu_irl_media_clock.h"

#include <math.h>

void tvu_irl_media_clock_init(tvu_irl_media_clock_t *c, double target_latency) {
    c->target_latency = target_latency;
    c->latest_audio_pts = 0.0;
    c->latest_video_pts = 0.0;
    c->has_audio_pts = false;
    c->has_video_pts = false;
    c->current_av_diff = INFINITY;
    c->estimated_av_diff = 0.0;
}

tvu_irl_media_clock_decision_t tvu_irl_media_clock_update(tvu_irl_media_clock_t *c) {
    tvu_irl_media_clock_decision_t decision = { 0.0, 0.0, false };
    if (!c->has_audio_pts || !c->has_video_pts) return decision;
    double av_diff = c->latest_audio_pts - c->latest_video_pts;
    c->has_audio_pts = false;
    c->has_video_pts = false;
    /* EMA：98% 历史 + 2% 当前。慢牵，避免高频抖动。 */
    c->estimated_av_diff = c->estimated_av_diff * 0.98 + av_diff * 0.02;
    if (fabs(c->estimated_av_diff - c->current_av_diff) <= 0.1) return decision;
    c->current_av_diff = c->estimated_av_diff;
    double video = c->target_latency;
    double audio = c->target_latency;
    if (av_diff > 0.0) audio += c->current_av_diff;
    else                video -= c->current_av_diff;
    decision.audio_target_latency = audio;
    decision.video_target_latency = video;
    decision.has_update = true;
    return decision;
}
