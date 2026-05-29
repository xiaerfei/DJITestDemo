/*
 * tvu_irl_audio_config.h
 *
 * 替代 TVUIRLAudioConfig。解析 AudioSpecificConfig (AAC 序列头)，
 * 提取 object_type / sample_rate / channel_count，构造 AudioStreamBasicDescription。
 *
 * 纯 POD，无 heap 分配，无生命周期问题。
 * 不提供 AVAudioFormat 出口：AVFoundation 是 ObjC，audio_decoder 改用
 * AudioConverter (C API) 直接吃 ASBD。
 */

#ifndef TVU_IRL_AUDIO_CONFIG_H
#define TVU_IRL_AUDIO_CONFIG_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    TVU_IRL_AAC_UNKNOWN    = 0,
    TVU_IRL_AAC_MAIN       = 1,
    TVU_IRL_AAC_LC         = 2,
    TVU_IRL_AAC_SSR        = 3,
    TVU_IRL_AAC_LTP        = 4,
    TVU_IRL_AAC_SBR        = 5,
    TVU_IRL_AAC_SCALABLE   = 6,
    TVU_IRL_AAC_TWIN_VQ    = 7,
    TVU_IRL_AAC_CELP       = 8,
    TVU_IRL_AAC_HVXC       = 9,
    TVU_IRL_AAC_OPUS       = 10,
} tvu_irl_aac_object_type_t;

typedef struct {
    tvu_irl_aac_object_type_t object_type;
    Float64                    sample_rate;
    uint8_t                    channel_count;
} tvu_irl_audio_config_t;

/* 从 AudioSpecificConfig 字节串解析。失败返回 false，c 状态未定义。 */
bool tvu_irl_audio_config_parse(tvu_irl_audio_config_t *c, const void *data, size_t length);

AudioStreamBasicDescription tvu_irl_audio_config_asbd(const tvu_irl_audio_config_t *c);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_AUDIO_CONFIG_H */
