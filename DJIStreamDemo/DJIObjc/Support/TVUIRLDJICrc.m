//
//  TVUIRLDJICrc.m
//  DJIStreamDemo
//

#import "TVUIRLDJICrc.h"

#pragma mark - 位反射工具函数

/// 8 位反射：把字节按位顺序倒过来（bit0↔bit7、bit1↔bit6 ...）。
/// CRC 算法的"输入反射 / 输出反射"步骤会用到。
static inline uint8_t reflect8(uint8_t v) {
    uint8_t x = v;
    x = ((x & 0xF0) >> 4) | ((x & 0x0F) << 4);  // 高 4 位 ↔ 低 4 位
    x = ((x & 0xCC) >> 2) | ((x & 0x33) << 2);  // 每 2 位为一组交换
    x = ((x & 0xAA) >> 1) | ((x & 0x55) << 1);  // 每 1 位交换
    return x;
}

/// 16 位反射，逻辑同 reflect8。
static inline uint16_t reflect16(uint16_t v) {
    uint16_t x = v;
    x = ((x & 0xFF00) >> 8) | ((x & 0x00FF) << 8);
    x = ((x & 0xF0F0) >> 4) | ((x & 0x0F0F) << 4);
    x = ((x & 0xCCCC) >> 2) | ((x & 0x3333) << 2);
    x = ((x & 0xAAAA) >> 1) | ((x & 0x5555) << 1);
    return x;
}

@implementation TVUIRLDJICrc

#pragma mark - CRC8

+ (uint8_t)crc8:(NSData *)data {
    // DJI 头部 CRC8 参数：多项式 0x31，初始值 0xEE，输入/输出均反射。
    const uint8_t poly = 0x31;
    uint8_t crc = 0xEE;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;

    for (NSUInteger i = 0; i < len; i++) {
        // 输入字节先做位反射，再异或到 crc 上
        crc ^= reflect8(bytes[i]);
        // 标准 CRC 移位算法：检查最高位决定是否异或多项式
        for (int j = 0; j < 8; j++) {
            if ((crc & 0x80) != 0) {
                crc = (uint8_t)((crc << 1) ^ poly);
            } else {
                crc = (uint8_t)(crc << 1);
            }
        }
    }
    // 输出再做一次位反射
    return reflect8(crc);
}

#pragma mark - CRC16

+ (uint16_t)crc16:(NSData *)data {
    // DJI 帧体 CRC16 参数：多项式 0x1021（CRC-CCITT），初始值 0x496C，输入/输出均反射。
    const uint16_t poly = 0x1021;
    uint16_t crc = 0x496C;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;

    for (NSUInteger i = 0; i < len; i++) {
        // 输入字节反射后，左移 8 位放到 CRC 高字节再异或
        crc ^= ((uint16_t)reflect8(bytes[i])) << 8;
        for (int j = 0; j < 8; j++) {
            if ((crc & 0x8000) != 0) {
                crc = (uint16_t)((crc << 1) ^ poly);
            } else {
                crc = (uint16_t)(crc << 1);
            }
        }
    }
    return reflect16(crc);
}

@end
