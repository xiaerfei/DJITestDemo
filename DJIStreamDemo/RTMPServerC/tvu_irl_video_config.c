/*
 * tvu_irl_video_config.c
 */

#include "tvu_irl_video_config.h"
#include "tvu_irl_io.h"

static const uint8_t kAvcReservedNumOfSpsMask = 0xE0;

/* ============================== AVC ============================== */

void tvu_irl_video_config_avc_init(tvu_irl_video_config_avc_t *c) {
    tvu_irl_bytes_init(&c->sps);
    tvu_irl_bytes_init(&c->pps);
}

void tvu_irl_video_config_avc_destroy(tvu_irl_video_config_avc_t *c) {
    tvu_irl_bytes_destroy(&c->sps);
    tvu_irl_bytes_destroy(&c->pps);
}

bool tvu_irl_video_config_avc_parse(tvu_irl_video_config_avc_t *c,
                                    const void *avcC_data, size_t avcC_length) {
    tvu_irl_reader_t r;
    tvu_irl_reader_init(&r, avcC_data, avcC_length);

    /* 跳过 6 字节配置头：
     *   configurationVersion(1) + AVCProfileIndication(1) + profile_compatibility(1)
     *   + AVCLevelIndication(1) + (6bit reserved + 2bit lengthSizeMinusOne)(1) → 共 5 字节
     *   接下来是 (3bit reserved + 5bit numOfSequenceParameterSets) → 单独读 */
    if (!tvu_irl_reader_skip(&r, 5)) return false;

    uint8_t numOfSpsWithReserved;
    if (!tvu_irl_reader_read_u8(&r, &numOfSpsWithReserved)) return false;
    uint8_t numOfSps = numOfSpsWithReserved & (uint8_t)~kAvcReservedNumOfSpsMask;
    for (uint8_t i = 0; i < numOfSps; i++) {
        uint16_t len;
        if (!tvu_irl_reader_read_be16(&r, &len)) return false;
        tvu_irl_strv_t view;
        if (!tvu_irl_reader_read_view(&r, &view, len)) return false;
        /* 重置 sps，再写入（多个 SPS 时保留最后一个，与 ObjC 行为一致） */
        tvu_irl_bytes_clear(&c->sps);
        tvu_irl_bytes_append(&c->sps, view.data, view.length);
    }
    uint8_t numOfPps;
    if (!tvu_irl_reader_read_u8(&r, &numOfPps)) return false;
    for (uint8_t i = 0; i < numOfPps; i++) {
        uint16_t len;
        if (!tvu_irl_reader_read_be16(&r, &len)) return false;
        tvu_irl_strv_t view;
        if (!tvu_irl_reader_read_view(&r, &view, len)) return false;
        tvu_irl_bytes_clear(&c->pps);
        tvu_irl_bytes_append(&c->pps, view.data, view.length);
    }
    return true;
}

OSStatus tvu_irl_video_config_avc_make_format_description(
    const tvu_irl_video_config_avc_t *c,
    CMVideoFormatDescriptionRef *out) {
    if (c->sps.length == 0 || c->pps.length == 0) {
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    }
    const uint8_t *pointers[2] = { c->sps.data, c->pps.data };
    const size_t   sizes[2]    = { c->sps.length, c->pps.length };
    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, pointers, sizes, 4, out);
}

/* ============================== HEVC ============================== */

void tvu_irl_video_config_hevc_init(tvu_irl_video_config_hevc_t *c) {
    tvu_irl_bytes_init(&c->vps);
    tvu_irl_bytes_init(&c->sps);
    tvu_irl_bytes_init(&c->pps);
}

void tvu_irl_video_config_hevc_destroy(tvu_irl_video_config_hevc_t *c) {
    tvu_irl_bytes_destroy(&c->vps);
    tvu_irl_bytes_destroy(&c->sps);
    tvu_irl_bytes_destroy(&c->pps);
}

bool tvu_irl_video_config_hevc_parse(tvu_irl_video_config_hevc_t *c,
                                     const void *hvcC_data, size_t hvcC_length) {
    tvu_irl_reader_t r;
    tvu_irl_reader_init(&r, hvcC_data, hvcC_length);

    /* HEVCDecoderConfigurationRecord 前 22 字节是头：
     *   configurationVersion(1) + general_profile_space/tier/profile_idc(1) + ...
     *   一直到 numTemporalLayers / temporalIdNested / lengthSizeMinusOne (22 字节) */
    if (!tvu_irl_reader_skip(&r, 22)) return false;

    uint8_t numberOfArrays;
    if (!tvu_irl_reader_read_u8(&r, &numberOfArrays)) return false;
    for (uint8_t i = 0; i < numberOfArrays; i++) {
        uint8_t header;
        if (!tvu_irl_reader_read_u8(&r, &header)) return false;
        uint8_t nal_unit_type = header & 0x3F;
        uint16_t num_nalus;
        if (!tvu_irl_reader_read_be16(&r, &num_nalus)) return false;
        for (uint16_t j = 0; j < num_nalus; j++) {
            uint16_t len;
            if (!tvu_irl_reader_read_be16(&r, &len)) return false;
            tvu_irl_strv_t view;
            if (!tvu_irl_reader_read_view(&r, &view, len)) return false;
            switch (nal_unit_type) {
                case TVU_IRL_HEVC_NAL_VPS:
                    tvu_irl_bytes_clear(&c->vps);
                    tvu_irl_bytes_append(&c->vps, view.data, view.length);
                    break;
                case TVU_IRL_HEVC_NAL_SPS:
                    tvu_irl_bytes_clear(&c->sps);
                    tvu_irl_bytes_append(&c->sps, view.data, view.length);
                    break;
                case TVU_IRL_HEVC_NAL_PPS:
                    tvu_irl_bytes_clear(&c->pps);
                    tvu_irl_bytes_append(&c->pps, view.data, view.length);
                    break;
                default:
                    break;
            }
        }
    }
    return true;
}

OSStatus tvu_irl_video_config_hevc_make_format_description(
    const tvu_irl_video_config_hevc_t *c,
    CMVideoFormatDescriptionRef *out) {
    if (c->vps.length == 0 || c->sps.length == 0 || c->pps.length == 0) {
        return kCMFormatDescriptionBridgeError_InvalidParameter;
    }
    const uint8_t *pointers[3] = { c->vps.data, c->sps.data, c->pps.data };
    const size_t   sizes[3]    = { c->vps.length, c->sps.length, c->pps.length };
    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault, 3, pointers, sizes, 4, NULL, out);
}
