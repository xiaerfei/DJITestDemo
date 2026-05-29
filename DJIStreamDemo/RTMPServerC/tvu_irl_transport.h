/*
 * tvu_irl_transport.h
 *
 * 替代 TVUIRLTransport 协议 + TVUIRLNetworkTransport。
 *
 * Network.framework C API 包装。AsyncSocket 后端已删除 —— production 路径只走
 * Network.framework，Plan 10 性能基线就建立在它上面。
 *
 * 对外接口：opaque struct + C 回调表，零 ObjC 依赖。
 *
 * 内存模型：
 *   - listener / connection 用 atomic 引用计数：caller 持 1 份；每个 in-flight
 *     的 nw block 持 1 份，block 退出时 release。所有引用归零时才 free 结构体，
 *     彻底杜绝"async callback fires after destroy"导致的 use-after-free。
 *   - nw_listener_t / nw_connection_t 在非 ARC C 下用 os_retain / os_release 显式管理
 *   - dispatch_queue_t 同样 dispatch_retain / dispatch_release
 */

#ifndef TVU_IRL_TRANSPORT_H
#define TVU_IRL_TRANSPORT_H

#include <Network/Network.h>
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tvu_irl_listener   tvu_irl_listener_t;
typedef struct tvu_irl_connection tvu_irl_connection_t;

/* 当新客户端连入时调用。conn 的所有权转给 caller —— caller 必须在不需要时
 * 调用 tvu_irl_connection_destroy。 */
typedef void (*tvu_irl_new_connection_handler_t)(tvu_irl_connection_t *conn, void *user);

/* 收到字节。data 仅在回调期间有效；caller 必须立即拷走或消费。 */
typedef void (*tvu_irl_receive_handler_t)(const uint8_t *data, size_t length, void *user);

/* 连接失败或对端关闭。error_code = 0 表示对端正常关闭。 */
typedef void (*tvu_irl_failure_handler_t)(int error_code, void *user);

/* ============================== Listener ============================== */

tvu_irl_listener_t *tvu_irl_listener_create(void);
void tvu_irl_listener_destroy(tvu_irl_listener_t *l);

/* 在 port 启动监听。失败返回 false。成功后异步在 queue 上回调 handler。 */
bool tvu_irl_listener_start(tvu_irl_listener_t *l,
                            uint16_t port,
                            dispatch_queue_t queue,
                            bool no_delay,
                            tvu_irl_new_connection_handler_t handler,
                            void *user);

void tvu_irl_listener_cancel(tvu_irl_listener_t *l);

/* ============================== Connection ============================== */

void tvu_irl_connection_destroy(tvu_irl_connection_t *c);

void tvu_irl_connection_start(tvu_irl_connection_t *c,
                              dispatch_queue_t queue,
                              tvu_irl_receive_handler_t receive,
                              tvu_irl_failure_handler_t failure,
                              void *user);

void tvu_irl_connection_write(tvu_irl_connection_t *c, const void *data, size_t length);

void tvu_irl_connection_cancel(tvu_irl_connection_t *c);

/* 调整下一次 nw_connection_receive 的 min_byte_count。握手期 = 1（每包都回调），
 * 进入媒体流后 caller 调成 8192 进入批量化模式（回调率从 ~250/s 降至 ~30/s）。 */
void tvu_irl_connection_set_receive_batch_min_bytes(tvu_irl_connection_t *c, uint32_t min_bytes);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_TRANSPORT_H */
