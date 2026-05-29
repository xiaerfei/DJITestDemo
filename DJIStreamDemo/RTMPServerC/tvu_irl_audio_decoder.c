/*
 * tvu_irl_audio_decoder.c
 */

#include "tvu_irl_audio_decoder.h"
#include "tvu_irl_log.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>

/* 目标 PCM：48kHz / stereo / Int16 / interleaved */
#define TVU_AUDIO_OUTPUT_SAMPLE_RATE 48000
#define TVU_AUDIO_OUTPUT_CHANNELS    2

static AudioStreamBasicDescription make_output_asbd(void) {
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate       = TVU_AUDIO_OUTPUT_SAMPLE_RATE;
    asbd.mFormatID         = kAudioFormatLinearPCM;
    asbd.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mFramesPerPacket  = 1;
    asbd.mChannelsPerFrame = TVU_AUDIO_OUTPUT_CHANNELS;
    asbd.mBitsPerChannel   = 16;
    asbd.mBytesPerFrame    = TVU_AUDIO_OUTPUT_CHANNELS * 2;  /* int16 interleaved */
    asbd.mBytesPerPacket   = asbd.mBytesPerFrame;             /* PCM: 1 frame/packet */
    return asbd;
}

void tvu_irl_audio_decoder_init(tvu_irl_audio_decoder_t *d) {
    memset(d, 0, sizeof(*d));
}

static void release_resources(tvu_irl_audio_decoder_t *d) {
    if (d->converter) {
        AudioConverterDispose(d->converter);
        d->converter = NULL;
    }
    if (d->output_format_desc) {
        CFRelease(d->output_format_desc);
        d->output_format_desc = NULL;
    }
    free(d->output_buffer);
    d->output_buffer = NULL;
    d->output_capacity_bytes = 0;
    d->output_capacity_frames = 0;
}

void tvu_irl_audio_decoder_destroy(tvu_irl_audio_decoder_t *d) {
    release_resources(d);
}

void tvu_irl_audio_decoder_set_callbacks(tvu_irl_audio_decoder_t *d,
                                         tvu_irl_audio_decoder_callbacks_t cb) {
    d->callbacks = cb;
}

void tvu_irl_audio_decoder_set_anchor(tvu_irl_audio_decoder_t *d,
                                      tvu_irl_decoded_pts_anchor_t anchor) {
    d->anchor = anchor;
    d->has_anchor = (anchor.remap_audio_pts != NULL);
}

bool tvu_irl_audio_decoder_configure(tvu_irl_audio_decoder_t *d,
                                     const tvu_irl_audio_config_t *config) {
    release_resources(d);

    d->input_asbd  = tvu_irl_audio_config_asbd(config);
    d->output_asbd = make_output_asbd();

    OSStatus s = AudioConverterNew(&d->input_asbd, &d->output_asbd, &d->converter);
    if (s != noErr || !d->converter) {
        TVU_IRL_LOG_ERROR("rtmp-server: AudioConverterNew failed: %d", (int)s);
        return false;
    }

    /* 输出 format description（CMSampleBuffer 用）。 */
    s = CMAudioFormatDescriptionCreate(
        kCFAllocatorDefault, &d->output_asbd, 0, NULL, 0, NULL, NULL, &d->output_format_desc);
    if (s != noErr || !d->output_format_desc) {
        TVU_IRL_LOG_ERROR("rtmp-server: CMAudioFormatDescriptionCreate failed: %d", (int)s);
        release_resources(d);
        return false;
    }

    /* AAC 每帧 1024 samples；重采样到 48k 后 = ceil(1024 * 48000 / src_rate) + 16 容差 */
    Float64 sr = d->input_asbd.mSampleRate > 0 ? d->input_asbd.mSampleRate : 48000;
    d->output_capacity_frames = (UInt32)ceil(1024.0 * (double)TVU_AUDIO_OUTPUT_SAMPLE_RATE / sr) + 16;
    d->output_capacity_bytes  = d->output_capacity_frames * d->output_asbd.mBytesPerFrame;
    d->output_buffer = (uint8_t *)malloc(d->output_capacity_bytes);
    if (!d->output_buffer) abort();

    TVU_IRL_LOG("rtmp-server: AAC type=%d rate=%.0f ch=%u → PCM 48k stereo Int16 (cap %u frames)",
                (int)config->object_type, sr, (unsigned)config->channel_count, d->output_capacity_frames);
    return true;
}

/* AudioConverter input callback：每次 decode 调用一次，提供一帧 AAC 数据。 */
static OSStatus input_callback(
    AudioConverterRef converter,
    UInt32 *io_num_packets,
    AudioBufferList *io_data,
    AudioStreamPacketDescription **out_pkt_desc,
    void *user_data)
{
    (void)converter;
    tvu_irl_audio_decoder_t *d = (tvu_irl_audio_decoder_t *)user_data;
    if (d->feed.provided) {
        *io_num_packets = 0;
        return noErr;
    }
    d->feed.provided = true;
    io_data->mNumberBuffers = 1;
    io_data->mBuffers[0].mNumberChannels = d->input_asbd.mChannelsPerFrame;
    io_data->mBuffers[0].mDataByteSize   = d->feed.length;
    io_data->mBuffers[0].mData           = (void *)d->feed.data;   /* AudioConverter 只读 */
    if (out_pkt_desc) *out_pkt_desc = &d->feed.pkt_desc;
    *io_num_packets = 1;
    return noErr;
}

static CMSampleBufferRef make_sample_buffer(
    tvu_irl_audio_decoder_t *d, UInt32 frames_produced, CMTime pts)
{
    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = d->output_asbd.mChannelsPerFrame;
    abl.mBuffers[0].mDataByteSize   = frames_produced * d->output_asbd.mBytesPerFrame;
    abl.mBuffers[0].mData           = d->output_buffer;

    CMSampleBufferRef sb = NULL;
    OSStatus s = CMAudioSampleBufferCreateWithPacketDescriptions(
        kCFAllocatorDefault, NULL, false, NULL, NULL,
        d->output_format_desc,
        (CMItemCount)frames_produced, pts, NULL, &sb);
    if (s != noErr || !sb) return NULL;

    s = CMSampleBufferSetDataBufferFromAudioBufferList(
        sb, kCFAllocatorDefault, kCFAllocatorDefault, 0, &abl);
    if (s != noErr) {
        CFRelease(sb);
        return NULL;
    }
    return sb;
}

void tvu_irl_audio_decoder_decode_aac(tvu_irl_audio_decoder_t *d,
                                      const void *aac_frame, size_t length,
                                      CMTime pts) {
    if (!d->converter || !aac_frame || length == 0) return;
    if (length > 0xFFFFFFFFu) return;

    d->feed.data   = (const uint8_t *)aac_frame;
    d->feed.length = (UInt32)length;
    d->feed.pkt_desc.mStartOffset             = 0;
    d->feed.pkt_desc.mVariableFramesInPacket  = 0;
    d->feed.pkt_desc.mDataByteSize            = (UInt32)length;
    d->feed.provided                          = false;

    AudioBufferList out_abl;
    out_abl.mNumberBuffers = 1;
    out_abl.mBuffers[0].mNumberChannels = d->output_asbd.mChannelsPerFrame;
    out_abl.mBuffers[0].mDataByteSize   = d->output_capacity_bytes;
    out_abl.mBuffers[0].mData           = d->output_buffer;

    UInt32 num_packets = d->output_capacity_frames;   /* PCM: packet == frame */
    OSStatus s = AudioConverterFillComplexBuffer(
        d->converter, input_callback, d, &num_packets, &out_abl, NULL);
    if (s != noErr) {
        TVU_IRL_LOG_ERROR("rtmp-server: AudioConverterFillComplexBuffer failed: %d", (int)s);
        return;
    }
    if (num_packets == 0) return;

    /* PTS 重锚（anchor 返回 invalid 表示丢帧） */
    CMTime remapped = pts;
    if (d->has_anchor && d->anchor.remap_audio_pts) {
        remapped = d->anchor.remap_audio_pts(pts, d->anchor.user);
        if (!CMTIME_IS_VALID(remapped)) return;
    }

    CMSampleBufferRef sb = make_sample_buffer(d, num_packets, remapped);
    if (!sb) return;
    if (d->callbacks.on_sample_buffer) {
        d->callbacks.on_sample_buffer(sb, d->callbacks.user);
    }
    CFRelease(sb);
}
