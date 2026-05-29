/*
 * tvu_irl_audio_decoder.h
 *
 * 替代 TVUIRLAudioDecoder。AAC → PCM (48kHz / stereo / Int16 / interleaved)。
 *
 * 用 AudioToolbox.AudioConverter（C API）替代 AVAudioConverter，消除整个
 * AVFoundation 依赖（AVAudioFormat / AVAudioCompressedBuffer / AVAudioPCMBuffer
 * 全是 ObjC 类）。
 *
 * 输出格式与 TVU encoder 期望保持一致：AVAudioConverter 一次性完成 AAC 解码
 * + 重采样 + 声道适配，下游不需要再做 PCM→PCM 转换。
 *
 * 线程模型：configure 单线程；decode 由 caller queue 串行调用；callback 在
 * 调用 decode 的同一线程触发（AudioConverterFillComplexBuffer 同步）。
 *
 * 内存模型：
 *   - converter / output_format_desc：CFRetain/CFRelease 配对
 *   - output_buffer：configure 时 malloc，destroy 时 free，每次 decode 复用
 */

#ifndef TVU_IRL_AUDIO_DECODER_H
#define TVU_IRL_AUDIO_DECODER_H

#include "tvu_irl_decoded_pts_anchor.h"
#include "tvu_irl_audio_config.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void (*on_sample_buffer)(CMSampleBufferRef sb, void *user);
    void *user;
} tvu_irl_audio_decoder_callbacks_t;

typedef struct {
    AudioConverterRef            converter;            /* NULL 表示未配置 */
    AudioStreamBasicDescription  input_asbd;
    AudioStreamBasicDescription  output_asbd;
    uint8_t                     *output_buffer;        /* owned，长度 = output_capacity_bytes */
    UInt32                       output_capacity_bytes;
    UInt32                       output_capacity_frames;
    CMAudioFormatDescriptionRef  output_format_desc;   /* CFRetain */

    /* 每次 decode 内部用，由 input callback 填充 */
    struct {
        const uint8_t              *data;
        UInt32                      length;
        AudioStreamPacketDescription pkt_desc;
        bool                        provided;
    } feed;

    tvu_irl_audio_decoder_callbacks_t callbacks;
    tvu_irl_decoded_pts_anchor_t       anchor;
    bool                               has_anchor;
} tvu_irl_audio_decoder_t;

void tvu_irl_audio_decoder_init(tvu_irl_audio_decoder_t *d);
void tvu_irl_audio_decoder_destroy(tvu_irl_audio_decoder_t *d);

void tvu_irl_audio_decoder_set_callbacks(tvu_irl_audio_decoder_t *d,
                                         tvu_irl_audio_decoder_callbacks_t cb);
void tvu_irl_audio_decoder_set_anchor(tvu_irl_audio_decoder_t *d,
                                      tvu_irl_decoded_pts_anchor_t anchor);

bool tvu_irl_audio_decoder_configure(tvu_irl_audio_decoder_t *d,
                                     const tvu_irl_audio_config_t *config);

static inline bool tvu_irl_audio_decoder_is_ready(const tvu_irl_audio_decoder_t *d) {
    return d->converter != NULL;
}

void tvu_irl_audio_decoder_decode_aac(tvu_irl_audio_decoder_t *d,
                                      const void *aac_frame, size_t length,
                                      CMTime pts);

#ifdef __cplusplus
}
#endif

#endif /* TVU_IRL_AUDIO_DECODER_H */
