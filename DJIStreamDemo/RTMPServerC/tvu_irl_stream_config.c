/*
 * tvu_irl_stream_config.c
 */

#include "tvu_irl_stream_config.h"

#include <stdlib.h>
#include <string.h>

/* ---------- Profile ---------- */

void tvu_irl_stream_profile_init(tvu_irl_stream_profile_t *p,
                                 tvu_irl_strv_t stream_key,
                                 int32_t latency_ms) {
    tvu_irl_str_init_with_view(&p->stream_key, stream_key);
    p->latency_ms = latency_ms;
    uuid_generate_random(p->uuid);
}

void tvu_irl_stream_profile_init_with_uuid(tvu_irl_stream_profile_t *p,
                                           tvu_irl_strv_t stream_key,
                                           int32_t latency_ms,
                                           const uuid_t uuid) {
    tvu_irl_str_init_with_view(&p->stream_key, stream_key);
    p->latency_ms = latency_ms;
    memcpy(p->uuid, uuid, sizeof(uuid_t));
}

void tvu_irl_stream_profile_destroy(tvu_irl_stream_profile_t *p) {
    tvu_irl_str_destroy(&p->stream_key);
    p->latency_ms = 0;
    memset(p->uuid, 0, sizeof(uuid_t));
}

/* ---------- Config ---------- */

static void grow_streams(tvu_irl_stream_config_t *c, size_t min_cap) {
    if (c->streams_capacity >= min_cap) return;
    size_t new_cap = c->streams_capacity ? c->streams_capacity : 2;
    while (new_cap < min_cap) new_cap <<= 1;
    tvu_irl_stream_profile_t *p = (tvu_irl_stream_profile_t *)
        realloc(c->streams, new_cap * sizeof(tvu_irl_stream_profile_t));
    if (!p) abort();
    c->streams = p;
    c->streams_capacity = new_cap;
}

void tvu_irl_stream_config_init(tvu_irl_stream_config_t *c) {
    c->port = 1935;
    c->no_delay = true;
    c->streams = NULL;
    c->num_streams = 0;
    c->streams_capacity = 0;
}

void tvu_irl_stream_config_init_with(tvu_irl_stream_config_t *c,
                                     uint16_t port,
                                     bool no_delay) {
    c->port = port;
    c->no_delay = no_delay;
    c->streams = NULL;
    c->num_streams = 0;
    c->streams_capacity = 0;
}

void tvu_irl_stream_config_destroy(tvu_irl_stream_config_t *c) {
    for (size_t i = 0; i < c->num_streams; i++) {
        tvu_irl_stream_profile_destroy(&c->streams[i]);
    }
    free(c->streams);
    c->streams = NULL;
    c->num_streams = 0;
    c->streams_capacity = 0;
    c->port = 0;
    c->no_delay = false;
}

void tvu_irl_stream_config_add_stream(tvu_irl_stream_config_t *c,
                                      tvu_irl_strv_t stream_key,
                                      int32_t latency_ms) {
    grow_streams(c, c->num_streams + 1);
    tvu_irl_stream_profile_init(&c->streams[c->num_streams], stream_key, latency_ms);
    c->num_streams++;
}

const tvu_irl_stream_profile_t *
tvu_irl_stream_config_find(const tvu_irl_stream_config_t *c, tvu_irl_strv_t stream_key) {
    for (size_t i = 0; i < c->num_streams; i++) {
        if (tvu_irl_strv_equals(tvu_irl_str_view(&c->streams[i].stream_key), stream_key)) {
            return &c->streams[i];
        }
    }
    return NULL;
}

void tvu_irl_stream_config_clone(tvu_irl_stream_config_t *dst,
                                 const tvu_irl_stream_config_t *src) {
    dst->port = src->port;
    dst->no_delay = src->no_delay;
    dst->streams = NULL;
    dst->num_streams = 0;
    dst->streams_capacity = 0;
    if (src->num_streams == 0) return;
    grow_streams(dst, src->num_streams);
    for (size_t i = 0; i < src->num_streams; i++) {
        tvu_irl_stream_profile_init_with_uuid(
            &dst->streams[i],
            tvu_irl_str_view(&src->streams[i].stream_key),
            src->streams[i].latency_ms,
            src->streams[i].uuid);
    }
    dst->num_streams = src->num_streams;
}
