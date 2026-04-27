//
//  TVUIRLDJICrc.h
//  DJIStreamDemo
//
//  DJI 私有 BLE 协议中使用的 CRC 校验工具类。
//
//  DJI 数据帧使用了两种 CRC：
//    - CRC8 ：校验帧头部（前 3 个字节），多项式 0x31，初始值 0xEE，输入/输出反射
//    - CRC16：校验整个帧体（除 CRC16 自身），多项式 0x1021，初始值 0x496C，输入/输出反射
//
//  这些参数是从 Moblin 项目逆向得到的，详见工程根目录的 report.md 第 4.3 节。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLDJICrc : NSObject

/// 计算 DJI 帧头 CRC8 校验值。
/// @param data 待校验的字节序列（一般是帧的前 3 个字节：0x55、length、0x04）
/// @return 8 位 CRC 校验值
+ (uint8_t)crc8:(NSData *)data;

/// 计算 DJI 帧体 CRC16 校验值。
/// @param data 待校验的字节序列（除尾部 2 字节 CRC16 之外的所有字节）
/// @return 16 位 CRC 校验值
+ (uint16_t)crc16:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
