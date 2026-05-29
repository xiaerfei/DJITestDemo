/*
 * tvu_irl_log.h
 *
 * 替代 TVUIRLDJILog.h。提供基于 os_log 的纯 C 日志宏。
 * DEBUG 下输出，Release 下编译期消除为 no-op。
 * 全局 os_log_t 在模块加载时通过 __attribute__((constructor)) 初始化，
 * 调用点零额外开销（os_log 本身就是 async + lock-free）。
 *
 * 与 NSLog 不同：format string 必须是编译期字符串字面量 —— 这正好契合
 * os_log 的硬性要求，从源头消除运行时拼字符串。
 */

#ifndef TVU_IRL_LOG_H
#define TVU_IRL_LOG_H

#include <os/log.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 全局 os_log handle。模块加载时初始化，永不为 NULL。 */
extern os_log_t tvu_irl_log_handle;

#if DEBUG
#  define TVU_IRL_LOG(fmt, ...)       os_log(tvu_irl_log_handle,       "[TVU-DJI] " fmt, ##__VA_ARGS__)
#  define TVU_IRL_LOG_DEBUG(fmt, ...) os_log_debug(tvu_irl_log_handle, "[TVU-DJI] " fmt, ##__VA_ARGS__)
#  define TVU_IRL_LOG_INFO(fmt, ...)  os_log_info(tvu_irl_log_handle,  "[TVU-DJI] " fmt, ##__VA_ARGS__)
#else
#  define TVU_IRL_LOG(fmt, ...)       ((void)0)
#  define TVU_IRL_LOG_DEBUG(fmt, ...) ((void)0)
#  define TVU_IRL_LOG_INFO(fmt, ...)  ((void)0)
#endif

/* error / fault 在 Release 也保留，便于线上事故排查。 */
#define TVU_IRL_LOG_ERROR(fmt, ...) os_log_error(tvu_irl_log_handle, "[TVU-DJI] " fmt, ##__VA_ARGS__)
#define TVU_IRL_LOG_FAULT(fmt, ...) os_log_fault(tvu_irl_log_handle, "[TVU-DJI] " fmt, ##__VA_ARGS__)

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_LOG_H */
