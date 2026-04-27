//
//  TVUIRLDJIDeviceModel.h
//  DJIStreamDemo
//
//  从 BLE 广播包的 Manufacturer Data 中识别 DJI 设备及其具体型号。
//
//  Manufacturer Data 字节布局：
//    [0..1]  公司 ID  ：0xAA 0x08（DJI Technology Co. Ltd） 或 0xAA 0xF7（Xtra Ltd）
//    [2..3]  机型 ID  ：例如 0x15 0x00 = Osmo Action 5 Pro
//
//  参考 report.md 第 4.2 节"设备型号识别"。
//

#import <Foundation/Foundation.h>
#import "TVUIRLDJITypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLDJIDeviceModelDetector : NSObject

/// 判断给定的 Manufacturer Data 是否来自 DJI 相机。
/// 只看前 2 字节的厂商 ID。
+ (BOOL)isDjiDevice:(NSData *)manufacturerData;

/// 解析 Manufacturer Data 的字节 2-3，返回具体型号枚举。
/// 字节不足或不在已知映射表中返回 TVUIRLDJIDeviceModelUnknown。
+ (TVUIRLDJIDeviceModel)modelFromManufacturerData:(NSData *)manufacturerData;

@end

NS_ASSUME_NONNULL_END
