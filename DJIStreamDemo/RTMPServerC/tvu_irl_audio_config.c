/*
 * tvu_irl_audio_config.c
 */

#include "tvu_irl_audio_config.h"

#include <CoreAudio/CoreAudioTypes.h>

static Float64 sample_rate_from_index(uint8_t freq) {
    switch (freq) {
        case 0:  return 96000;
        case 1:  return 88200;
        case 2:  return 64000;
        case 3:  return 48000;
        case 4:  return 44100;
        case 5:  return 32000;
        case 6:  return 24000;
        case 7:  return 22050;
        case 8:  return 16000;
        case 9:  return 12000;
        case 10: return 11025;
        case 11: return 8000;
        case 12: return 7350;
        default: return 0;
    }
}

bool tvu_irl_audio_config_parse(tvu_irl_audio_config_t *c, const void *data, size_t length) {
    if (length < 2) return false;
    const uint8_t *b = (const uint8_t *)data;
    uint8_t type_raw = b[0] >> 3;
    uint8_t freq     = (uint8_t)(((b[0] & 0x07) << 1) | (b[1] >> 7));
    uint8_t channel  = (uint8_t)((b[1] & 0x78) >> 3);
    if (type_raw < 1 || type_raw > 10) return false;
    if (freq > 12) return false;
    if (channel > 7) return false;
    c->object_type   = (tvu_irl_aac_object_type_t)type_raw;
    c->sample_rate   = sample_rate_from_index(freq);
    c->channel_count = channel;
    return true;
}

AudioStreamBasicDescription tvu_irl_audio_config_asbd(const tvu_irl_audio_config_t *c) {
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate       = c->sample_rate;
    asbd.mFormatID         = kAudioFormatMPEG4AAC;
    asbd.mFormatFlags      = (UInt32)c->object_type;
    asbd.mBytesPerPacket   = 0;
    asbd.mFramesPerPacket  = 1024;
    asbd.mBytesPerFrame    = 0;
    asbd.mChannelsPerFrame = (UInt32)c->channel_count;
    asbd.mBitsPerChannel   = 0;
    asbd.mReserved         = 0;
    return asbd;
}
