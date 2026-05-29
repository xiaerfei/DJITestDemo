/*
 * tvu_irl_video_config.h
 *
 * 替代 TVUIRLVideoConfigAvc + TVUIRLVideoConfigHevc。
 *
 * 解析 AVCDecoderConfigurationRecord / HEVCDecoderConfigurationRecord，提取
 * 参数集 (SPS/PPS 或 VPS/SPS/PPS)，生成 CMVideoFormatDescription（VTDecompressionSession 的输入）。
 *
 * NAL 数据持有副本（init_from 接受裸字节，函数内深拷贝）—— DJI 相机
 * sequenceStart 只发一次，整个会话只解析一次，复制开销可忽略。
 */

#ifndef TVU_IRL_VIDEO_CONFIG_H
#define TVU_IRL_VIDEO_CONFIG_H

#include "tvu_irl_bytes.h"

#include <CoreMedia/CoreMedia.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* HEVC NAL unit type（与 ObjC 同步）。 */
typedef enum {
    TVU_IRL_HEVC_NAL_VPS     = 32,
    TVU_IRL_HEVC_NAL_SPS     = 33,
    TVU_IRL_HEVC_NAL_PPS     = 34,
    TVU_IRL_HEVC_NAL_UNSPEC  = 0xFF,
} tvu_irl_hevc_nal_type_t;

/* ---------- AVC (H.264) ---------- */

typedef struct {
    tvu_irl_bytes_t sps;
    tvu_irl_bytes_t pps;
} tvu_irl_video_config_avc_t;

void tvu_irl_video_config_avc_init(tvu_irl_video_config_avc_t *c);
void tvu_irl_video_config_avc_destroy(tvu_irl_video_config_avc_t *c);

/* 解析 avcC 字节串到 sps/pps。成功 true。失败时部分字段可能已填，外部应 destroy。 */
bool tvu_irl_video_config_avc_parse(tvu_irl_video_config_avc_t *c,
                                    const void *avcC_data, size_t avcC_length);

OSStatus tvu_irl_video_config_avc_make_format_description(
    const tvu_irl_video_config_avc_t *c,
    CMVideoFormatDescriptionRef *out);

/* ---------- HEVC (H.265) ---------- */

typedef struct {
    tvu_irl_bytes_t vps;
    tvu_irl_bytes_t sps;
    tvu_irl_bytes_t pps;
} tvu_irl_video_config_hevc_t;

void tvu_irl_video_config_hevc_init(tvu_irl_video_config_hevc_t *c);
void tvu_irl_video_config_hevc_destroy(tvu_irl_video_config_hevc_t *c);

bool tvu_irl_video_config_hevc_parse(tvu_irl_video_config_hevc_t *c,
                                     const void *hvcC_data, size_t hvcC_length);

OSStatus tvu_irl_video_config_hevc_make_format_description(
    const tvu_irl_video_config_hevc_t *c,
    CMVideoFormatDescriptionRef *out);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_VIDEO_CONFIG_H */
