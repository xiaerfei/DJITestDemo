/*
 * tvu_irl_streaming_server.c
 *
 * 端口监听 + 多客户端管理 + 周期 timeout 探测 + 回调转发。
 *
 * 连接生命周期：
 *   - 新连接到达时 → 创建 stream_connection_t，放入 connections 数组
 *   - 连接断开 → server_connection_did_disconnect 被调用：
 *       1) stream_connection_stop（标 transport cancelled）
 *       2) 触发 on_publish_stop 回调
 *       3) 从数组中移除
 *       4) dispatch_async 到 server queue 销毁（保证当前帧 process_received
 *          完整返回后才 free，避免栈上 UAF）
 */

#include "tvu_irl_streaming_server.h"
#include "tvu_irl_stream_connection.h"
#include "tvu_irl_transport.h"
#include "tvu_irl_bandwidth_meter.h"
#include "tvu_irl_log.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CONNECTIONS 8
#define RECEIVE_TIMEOUT_SECONDS 10.0

struct tvu_irl_streaming_server {
    tvu_irl_stream_config_t      config;
    tvu_irl_server_callbacks_t   callbacks;

    dispatch_queue_t             queue;
    tvu_irl_listener_t          *listener;
    tvu_irl_bandwidth_meter_t    meter;
    dispatch_source_t            periodic_timer;

    tvu_irl_stream_connection_t *connections[MAX_CONNECTIONS];
    size_t                       num_connections;

    bool                         started;
};

/* ============================== 内部 ============================== */

static void notify_publish_stop(tvu_irl_streaming_server_t *s,
                                tvu_irl_stream_connection_t *c, const char *reason) {
    const char *key = tvu_irl_stream_connection_stream_key(c);
    if (key && key[0] != '\0' && s->callbacks.on_publish_stop) {
        s->callbacks.on_publish_stop(key, reason ? reason : "", s->callbacks.user);
    }
}

static void remove_from_list(tvu_irl_streaming_server_t *s,
                             tvu_irl_stream_connection_t *c) {
    size_t found = SIZE_MAX;
    for (size_t i = 0; i < s->num_connections; i++) {
        if (s->connections[i] == c) { found = i; break; }
    }
    if (found == SIZE_MAX) return;
    for (size_t i = found; i + 1 < s->num_connections; i++) {
        s->connections[i] = s->connections[i + 1];
    }
    s->num_connections--;
}

/* ============================== 内部接口（连接调用） ============================== */

dispatch_queue_t tvu_irl_streaming_server_queue(tvu_irl_streaming_server_t *s) {
    return s->queue;
}

const tvu_irl_stream_config_t *tvu_irl_streaming_server_config(tvu_irl_streaming_server_t *s) {
    return &s->config;
}

void tvu_irl_streaming_server_bandwidth_add(tvu_irl_streaming_server_t *s, size_t bytes) {
    tvu_irl_bandwidth_meter_add(&s->meter, bytes);
}

void tvu_irl_streaming_server_connection_did_complete(
    tvu_irl_streaming_server_t *s, tvu_irl_stream_connection_t *c) {
    const char *key = tvu_irl_stream_connection_stream_key(c);
    /* 同 streamKey 的旧连接踢掉 */
    for (size_t i = 0; i < s->num_connections; ) {
        tvu_irl_stream_connection_t *other = s->connections[i];
        if (other != c) {
            const char *okey = tvu_irl_stream_connection_stream_key(other);
            if (okey && key && strcmp(okey, key) == 0) {
                if (s->callbacks.on_publish_stop) {
                    s->callbacks.on_publish_stop(key, "Same stream key", s->callbacks.user);
                }
                tvu_irl_stream_connection_stop(other, "Same stream key");
                remove_from_list(s, other);
                tvu_irl_stream_connection_t *to_destroy = other;
                dispatch_async(s->queue, ^{
                    tvu_irl_stream_connection_destroy(to_destroy);
                });
                continue;   /* 不增 i：已移除当前槽位 */
            }
        }
        i++;
    }
    if (s->callbacks.on_publish_start) {
        s->callbacks.on_publish_start(key, s->callbacks.user);
    }
}

void tvu_irl_streaming_server_connection_did_disconnect(
    tvu_irl_streaming_server_t *s, tvu_irl_stream_connection_t *c, const char *reason) {
    tvu_irl_stream_connection_stop(c, reason);
    notify_publish_stop(s, c, reason);
    remove_from_list(s, c);
    dispatch_async(s->queue, ^{
        tvu_irl_stream_connection_destroy(c);
    });
}

void tvu_irl_streaming_server_forward_video_sample(
    tvu_irl_streaming_server_t *s, CMSampleBufferRef sb) {
    if (s->callbacks.on_video_sample_buffer) s->callbacks.on_video_sample_buffer(sb, s->callbacks.user);
}
void tvu_irl_streaming_server_forward_video_image(
    tvu_irl_streaming_server_t *s, CVImageBufferRef ib) {
    if (s->callbacks.on_video_image_buffer) s->callbacks.on_video_image_buffer(ib, s->callbacks.user);
}
void tvu_irl_streaming_server_forward_audio_sample(
    tvu_irl_streaming_server_t *s, CMSampleBufferRef sb) {
    if (s->callbacks.on_audio_sample_buffer) s->callbacks.on_audio_sample_buffer(sb, s->callbacks.user);
}
void tvu_irl_streaming_server_forward_target_latencies(
    tvu_irl_streaming_server_t *s, double video, double audio) {
    if (s->callbacks.on_target_latencies) s->callbacks.on_target_latencies(video, audio, s->callbacks.user);
}

/* ============================== Listener callback ============================== */

static void on_new_connection(tvu_irl_connection_t *conn, void *user) {
    tvu_irl_streaming_server_t *s = (tvu_irl_streaming_server_t *)user;
    if (s->num_connections >= MAX_CONNECTIONS) {
        TVU_IRL_LOG_ERROR("rtmp-server: too many connections (%zu), reject", s->num_connections);
        tvu_irl_connection_destroy(conn);
        return;
    }
    tvu_irl_stream_connection_t *sc = tvu_irl_stream_connection_create(s, conn);
    s->connections[s->num_connections++] = sc;
    tvu_irl_stream_connection_start(sc);
    TVU_IRL_LOG("[leak-check] new connection, total active=%zu", s->num_connections);
}

/* ============================== Periodic timer ============================== */

static void periodic_tick(tvu_irl_streaming_server_t *s) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    /* 反向遍历，方便边走边删 */
    for (size_t i = s->num_connections; i > 0; i--) {
        tvu_irl_stream_connection_t *c = s->connections[i - 1];
        if (now - tvu_irl_stream_connection_latest_receive_time(c) > RECEIVE_TIMEOUT_SECONDS) {
            tvu_irl_streaming_server_connection_did_disconnect(s, c, "Receive timeout");
        }
    }
}

static void setup_periodic_timer(tvu_irl_streaming_server_t *s) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, s->queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        periodic_tick(s);
    });
    dispatch_resume(timer);
    s->periodic_timer = timer;
}

/* ============================== 对外 API ============================== */

tvu_irl_streaming_server_t *tvu_irl_streaming_server_create(
    const tvu_irl_stream_config_t *config,
    tvu_irl_server_callbacks_t callbacks) {
    tvu_irl_streaming_server_t *s = (tvu_irl_streaming_server_t *)calloc(1, sizeof(*s));
    if (!s) abort();
    tvu_irl_stream_config_clone(&s->config, config);
    s->callbacks = callbacks;
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    s->queue = dispatch_queue_create("com.tvunetworks.rtmp-server", attr);
    tvu_irl_bandwidth_meter_init(&s->meter);
    return s;
}

void tvu_irl_streaming_server_destroy(tvu_irl_streaming_server_t *s) {
    if (!s) return;
    tvu_irl_streaming_server_stop(s);
    tvu_irl_stream_config_destroy(&s->config);
    if (s->queue) {
        dispatch_release(s->queue);
        s->queue = NULL;
    }
    free(s);
}

bool tvu_irl_streaming_server_start(tvu_irl_streaming_server_t *s) {
    if (!s || s->started) return false;
    __block bool ok = false;
    dispatch_sync(s->queue, ^{
        s->listener = tvu_irl_listener_create();
        ok = tvu_irl_listener_start(s->listener, s->config.port, s->queue, s->config.no_delay,
                                    on_new_connection, s);
        if (ok) {
            setup_periodic_timer(s);
            s->started = true;
            TVU_IRL_LOG("rtmp-server: listening on port %u", (unsigned)s->config.port);
        } else {
            tvu_irl_listener_destroy(s->listener);
            s->listener = NULL;
            TVU_IRL_LOG_ERROR("rtmp-server: failed to start listener on port %u", (unsigned)s->config.port);
        }
    });
    return ok;
}

void tvu_irl_streaming_server_stop(tvu_irl_streaming_server_t *s) {
    if (!s) return;
    dispatch_sync(s->queue, ^{
        for (size_t i = 0; i < s->num_connections; i++) {
            tvu_irl_stream_connection_stop(s->connections[i], "Server stop");
            tvu_irl_stream_connection_destroy(s->connections[i]);
            s->connections[i] = NULL;
        }
        s->num_connections = 0;
        if (s->listener) {
            tvu_irl_listener_destroy(s->listener);
            s->listener = NULL;
        }
        if (s->periodic_timer) {
            dispatch_source_cancel(s->periodic_timer);
            dispatch_release(s->periodic_timer);
            s->periodic_timer = NULL;
        }
        s->started = false;
    });
}

bool tvu_irl_streaming_server_is_stream_connected(
    const tvu_irl_streaming_server_t *s, const char *stream_key) {
    if (!s || !stream_key) return false;
    __block bool connected = false;
    tvu_irl_streaming_server_t *ms = (tvu_irl_streaming_server_t *)s;
    dispatch_sync(ms->queue, ^{
        for (size_t i = 0; i < ms->num_connections; i++) {
            const char *k = tvu_irl_stream_connection_stream_key(ms->connections[i]);
            if (k && strcmp(k, stream_key) == 0) { connected = true; break; }
        }
    });
    return connected;
}

size_t tvu_irl_streaming_server_num_clients(const tvu_irl_streaming_server_t *s) {
    if (!s) return 0;
    __block size_t n = 0;
    tvu_irl_streaming_server_t *ms = (tvu_irl_streaming_server_t *)s;
    dispatch_sync(ms->queue, ^{ n = ms->num_connections; });
    return n;
}

tvu_irl_bandwidth_snapshot_t tvu_irl_streaming_server_update_stats(tvu_irl_streaming_server_t *s) {
    __block tvu_irl_bandwidth_snapshot_t snap = { 0, 0 };
    if (!s) return snap;
    dispatch_sync(s->queue, ^{ snap = tvu_irl_bandwidth_meter_update(&s->meter); });
    return snap;
}
