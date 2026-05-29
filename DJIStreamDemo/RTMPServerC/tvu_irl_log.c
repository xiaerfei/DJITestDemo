/*
 * tvu_irl_log.c
 *
 * 全局 os_log_t 单例初始化。constructor 在 dyld 装载时执行一次，
 * 无需 dispatch_once / pthread_once。
 */

#include "tvu_irl_log.h"

os_log_t tvu_irl_log_handle;

__attribute__((constructor))
static void tvu_irl_log_module_init(void) {
    tvu_irl_log_handle = os_log_create("com.tvunetworks.rtmp", "RTMPServer");
}
