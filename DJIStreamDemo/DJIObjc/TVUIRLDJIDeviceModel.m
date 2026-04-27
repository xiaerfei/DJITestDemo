//
//  TVUIRLDJIDeviceModel.m
//  DJIStreamDemo
//

#import "TVUIRLDJIDeviceModel.h"

@implementation TVUIRLDJIDeviceModelDetector

+ (BOOL)isDjiDevice:(NSData *)manufacturerData {
    if (manufacturerData.length < 2) return NO;
    const uint8_t *bytes = (const uint8_t *)manufacturerData.bytes;
    // DJI Technology Co. Ltd 厂商 ID（绝大多数官方机型使用）
    if (bytes[0] == 0xAA && bytes[1] == 0x08) return YES;
    // Xtra Ltd 厂商 ID（DJI 子品牌或某些固件版本会使用）
    if (bytes[0] == 0xAA && bytes[1] == 0xF7) return YES;
    return NO;
}

+ (TVUIRLDJIDeviceModel)modelFromManufacturerData:(NSData *)manufacturerData {
    // 至少需要 4 字节才能读到机型字段
    if (manufacturerData.length < 4) return TVUIRLDJIDeviceModelUnknown;

    const uint8_t *bytes = (const uint8_t *)manufacturerData.bytes;
    uint8_t b2 = bytes[2];
    uint8_t b3 = bytes[3];

    // 已知机型的字节 3 都是 0x00；不是 0x00 视为未知
    if (b3 != 0x00) return TVUIRLDJIDeviceModelUnknown;

    // 机型映射表（来源 report.md 第 4.2 节）
    switch (b2) {
        case 0x10: return TVUIRLDJIDeviceModelOsmoAction2;
        case 0x12: return TVUIRLDJIDeviceModelOsmoAction3;
        case 0x14: return TVUIRLDJIDeviceModelOsmoAction4;
        case 0x15: return TVUIRLDJIDeviceModelOsmoAction5Pro;
        case 0x17: return TVUIRLDJIDeviceModelOsmo360;
        case 0x18: return TVUIRLDJIDeviceModelOsmoAction6;
        case 0x20: return TVUIRLDJIDeviceModelOsmoPocket3;
        default:   return TVUIRLDJIDeviceModelUnknown;
    }
}

@end
