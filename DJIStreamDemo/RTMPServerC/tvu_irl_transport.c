/*
 * tvu_irl_transport.c
 *
 * Network.framework C API 实现。
 *
 * 引用计数细节：
 *   - create 后 refcount = 1（caller 持有）
 *   - 每个进入异步 block 的路径：connection_retain → block 完成时 connection_release
 *   - destroy 触发 cancel + caller-side release
 *   - free 时机：refcount → 0，所有 in-flight block 都完成
 *
 * 性能：
 *   - receive callback 用 dispatch_data_create_map 拿到 flat 指针，单次 memcpy 兜底
 *     （已 contiguous 时零拷贝）。然后回调 caller，caller 在 hot path 上自己处理
 *   - write 路径：dispatch_data_create 包装 caller buffer，DISPATCH_DATA_DESTRUCTOR_DEFAULT
 *     使 dispatch 自动复制；caller 可立即释放原 buffer
 */

#include "tvu_irl_transport.h"
#include "tvu_irl_log.h"

#include <CoreFoundation/CoreFoundation.h>
#include <os/object.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <Block.h>

/* ============================== 公共内部 ============================== */

static inline void retain_queue(dispatch_queue_t q) { if (q) dispatch_retain(q); }
static inline void release_queue(dispatch_queue_t q) { if (q) dispatch_release(q); }

/* ============================== Connection ============================== */

struct tvu_irl_connection {
    nw_connection_t           connection;        /* os_retain'd */
    dispatch_queue_t          queue;             /* dispatch_retain'd */

    tvu_irl_receive_handler_t receive_handler;
    tvu_irl_failure_handler_t failure_handler;
    void                     *user;

    _Atomic int               refcount;
    _Atomic bool              cancelled;
    _Atomic uint32_t          receive_batch_min_bytes;

    /* receive 统计（仅在 nw queue 单线程访问，不需要原子） */
    size_t                    stats_callbacks;
    size_t                    stats_bytes;
    CFAbsoluteTime            stats_window_start;
};

static void connection_retain(tvu_irl_connection_t *c) {
    atomic_fetch_add_explicit(&c->refcount, 1, memory_order_relaxed);
}

static void connection_release(tvu_irl_connection_t *c) {
    if (atomic_fetch_sub_explicit(&c->refcount, 1, memory_order_acq_rel) == 1) {
        if (c->connection) { os_release(c->connection); c->connection = NULL; }
        release_queue(c->queue); c->queue = NULL;
        free(c);
    }
}

static tvu_irl_connection_t *connection_create(nw_connection_t nw_conn) {
    tvu_irl_connection_t *c = (tvu_irl_connection_t *)calloc(1, sizeof(*c));
    if (!c) abort();
    /* 持有 nw_connection。来源是 listener 的 new_connection_handler 中的参数，
     * 那里 nw framework 已经给 +1 引用计数（生命周期与 block 绑定）；这里再 retain
     * 一次，保证 connection 独立于 block 存活。 */
    c->connection = nw_conn;
    os_retain(c->connection);
    atomic_init(&c->refcount, 1);
    atomic_init(&c->cancelled, false);
    atomic_init(&c->receive_batch_min_bytes, 1);
    c->stats_window_start = CFAbsoluteTimeGetCurrent();
    return c;
}

void tvu_irl_connection_destroy(tvu_irl_connection_t *c) {
    if (!c) return;
    tvu_irl_connection_cancel(c);
    connection_release(c);
}

void tvu_irl_connection_cancel(tvu_irl_connection_t *c) {
    if (!c) return;
    bool already = atomic_exchange_explicit(&c->cancelled, true, memory_order_acq_rel);
    if (already) return;
    if (c->connection) {
        nw_connection_cancel(c->connection);
    }
}

void tvu_irl_connection_set_receive_batch_min_bytes(tvu_irl_connection_t *c, uint32_t min_bytes) {
    if (!c) return;
    atomic_store_explicit(&c->receive_batch_min_bytes,
                          min_bytes < 1 ? 1 : min_bytes,
                          memory_order_relaxed);
}

static void schedule_receive(tvu_irl_connection_t *c);

static void schedule_receive(tvu_irl_connection_t *c) {
    if (atomic_load_explicit(&c->cancelled, memory_order_relaxed)) return;
    uint32_t min_bytes = atomic_load_explicit(&c->receive_batch_min_bytes, memory_order_relaxed);
    connection_retain(c);
    nw_connection_receive(c->connection, min_bytes, 131072,
        ^(dispatch_data_t content, nw_content_context_t ctx, bool is_complete, nw_error_t error) {
            (void)ctx;
            if (atomic_load_explicit(&c->cancelled, memory_order_relaxed)) {
                connection_release(c);
                return;
            }
            size_t size = content ? dispatch_data_get_size(content) : 0;
            if (size > 0) {
                /* dispatch_data_create_map：connected/single-region 时返回零拷贝 view，
                 * fragmented 时一次 memcpy 到新 buffer。释放 mapped 即释放视图。 */
                const void *flat = NULL;
                size_t flat_size = 0;
                dispatch_data_t mapped = dispatch_data_create_map(content, &flat, &flat_size);
                c->stats_callbacks += 1;
                c->stats_bytes += flat_size;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                CFAbsoluteTime elapsed = now - c->stats_window_start;
                if (elapsed >= 1.0) {
                    TVU_IRL_LOG("[nw_recv] callbacks=%zu bytes=%zu (%.1f KB/s)",
                                c->stats_callbacks, c->stats_bytes,
                                (double)c->stats_bytes / elapsed / 1024.0);
                    c->stats_callbacks = 0; c->stats_bytes = 0;
                    c->stats_window_start = now;
                }
                if (c->receive_handler) {
                    c->receive_handler((const uint8_t *)flat, flat_size, c->user);
                }
                if (mapped) dispatch_release(mapped);
                schedule_receive(c);
            }
            if (error) {
                int code = nw_error_get_error_code(error);
                if (c->failure_handler) c->failure_handler(code, c->user);
            } else if (is_complete && size == 0) {
                if (c->failure_handler) c->failure_handler(0, c->user);
            }
            connection_release(c);
        });
}

void tvu_irl_connection_start(tvu_irl_connection_t *c,
                              dispatch_queue_t queue,
                              tvu_irl_receive_handler_t receive,
                              tvu_irl_failure_handler_t failure,
                              void *user) {
    if (!c || !queue) return;
    if (c->queue) release_queue(c->queue);
    c->queue = queue;
    retain_queue(c->queue);
    c->receive_handler = receive;
    c->failure_handler = failure;
    c->user = user;

    nw_connection_set_queue(c->connection, queue);
    /* 空 state changed handler：避免 nw framework 默认行为引发的 noise；不 capture self。 */
    nw_connection_set_state_changed_handler(c->connection,
        ^(nw_connection_state_t state, nw_error_t error) { (void)state; (void)error; });
    nw_connection_start(c->connection);
    schedule_receive(c);
}

void tvu_irl_connection_write(tvu_irl_connection_t *c, const void *data, size_t length) {
    if (!c || length == 0 || atomic_load_explicit(&c->cancelled, memory_order_relaxed)) return;
    /* DISPATCH_DATA_DESTRUCTOR_DEFAULT 让 dispatch 复制 data —— caller 可立即释放 buffer */
    dispatch_data_t dd = dispatch_data_create(data, length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(c->connection, dd, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
        ^(nw_error_t error) { (void)error; });
    dispatch_release(dd);
}

/* ============================== Listener ============================== */

struct tvu_irl_listener {
    nw_listener_t                     listener;
    dispatch_queue_t                  queue;
    tvu_irl_new_connection_handler_t  handler;
    void                             *user;
    _Atomic int                       refcount;
    _Atomic bool                      cancelled;
};

static void listener_retain(tvu_irl_listener_t *l) {
    atomic_fetch_add_explicit(&l->refcount, 1, memory_order_relaxed);
}

static void listener_release(tvu_irl_listener_t *l) {
    if (atomic_fetch_sub_explicit(&l->refcount, 1, memory_order_acq_rel) == 1) {
        if (l->listener) { os_release(l->listener); l->listener = NULL; }
        release_queue(l->queue); l->queue = NULL;
        free(l);
    }
}

tvu_irl_listener_t *tvu_irl_listener_create(void) {
    tvu_irl_listener_t *l = (tvu_irl_listener_t *)calloc(1, sizeof(*l));
    if (!l) abort();
    atomic_init(&l->refcount, 1);
    atomic_init(&l->cancelled, false);
    return l;
}

void tvu_irl_listener_destroy(tvu_irl_listener_t *l) {
    if (!l) return;
    tvu_irl_listener_cancel(l);
    listener_release(l);
}

void tvu_irl_listener_cancel(tvu_irl_listener_t *l) {
    if (!l) return;
    bool already = atomic_exchange_explicit(&l->cancelled, true, memory_order_acq_rel);
    if (already) return;
    if (l->listener) {
        nw_listener_set_state_changed_handler(l->listener, NULL);
        nw_listener_set_new_connection_handler(l->listener, NULL);
        nw_listener_cancel(l->listener);
    }
}

bool tvu_irl_listener_start(tvu_irl_listener_t *l,
                            uint16_t port,
                            dispatch_queue_t queue,
                            bool no_delay,
                            tvu_irl_new_connection_handler_t handler,
                            void *user) {
    if (!l || !queue) return false;
    l->handler = handler;
    l->user = user;
    if (l->queue) release_queue(l->queue);
    l->queue = queue;
    retain_queue(l->queue);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(params);
    nw_protocol_options_t tcp_opts = nw_protocol_stack_copy_transport_protocol(stack);
    if (tcp_opts) {
        nw_tcp_options_set_no_delay(tcp_opts, no_delay);
        os_release(tcp_opts);
    }
    os_release(stack);
    nw_parameters_set_reuse_local_address(params, true);

    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%u", (unsigned)port);
    nw_endpoint_t endpoint = nw_endpoint_create_host("0.0.0.0", port_str);
    nw_parameters_set_local_endpoint(params, endpoint);
    os_release(endpoint);

    nw_listener_t listener = nw_listener_create(params);
    os_release(params);
    if (!listener) {
        TVU_IRL_LOG_ERROR("rtmp-server: nw_listener_create failed");
        return false;
    }
    l->listener = listener;   /* listener 已经是 +1 from nw_listener_create */

    nw_listener_set_state_changed_handler(listener,
        ^(nw_listener_state_t state, nw_error_t err) {
            if (state == nw_listener_state_failed) {
                int code = err ? nw_error_get_error_code(err) : 0;
                TVU_IRL_LOG_ERROR("rtmp-server[Network]: listener failed: %d", code);
            }
        });
    /* 生命周期约束：caller 必须保证 destroy 调用前 listener 已经停止接受新连接
     * （cancel + dispatch_sync 串行）。不做引用计数保活 —— C 下没有 block destructor
     * hook 配合 C 指针，重型方案与本场景（server 单例）不匹配。 */
    nw_listener_set_new_connection_handler(listener,
        ^(nw_connection_t conn) {
            if (atomic_load_explicit(&l->cancelled, memory_order_relaxed)) return;
            if (l->handler) {
                tvu_irl_connection_t *wrapped = connection_create(conn);
                l->handler(wrapped, l->user);
            }
        });
    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);
    return true;
}
