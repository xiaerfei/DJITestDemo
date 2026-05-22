//
//  TVUIRLDJIDeviceScanner.h
//  DJIStreamDemo
//
//  扫描周围所有 BLE 设备，从中识别出 DJI 相机并通过 delegate 回调上层。
//
//  设计要点：
//    - 不使用 Service UUID 过滤，扫描全部设备（DJI 相机的 Service UUID 不固定）
//    - 通过解析 Manufacturer Data 识别 DJI 设备（见 TVUIRLDJIDeviceModelDetector）
//    - 同一台设备在扫描过程中会多次触发回调，本类内部去重，每台设备只回调一次
//    - 使用 sharedScanner 单例：BLE 扫描全局只能有一个 CBCentralManager 在跑
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "TVUIRLDJITypes.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 已发现设备的轻量包装

/// 表示扫描到的一台 DJI 设备：底层 CBPeripheral + 解析出的型号枚举。
@interface TVUIRLDJIDiscoveredDevice : NSObject

@property (nonatomic, strong, readonly) CBPeripheral *peripheral;
@property (nonatomic, assign, readonly) TVUIRLDJIDeviceModel model;

- (instancetype)initWithPeripheral:(CBPeripheral *)peripheral
                             model:(TVUIRLDJIDeviceModel)model;

@end

#pragma mark - 委托

@class TVUIRLDJIDeviceScanner;

@protocol TVUIRLDJIDeviceScannerDelegate <NSObject>

/// 发现一台新的 DJI 设备时回调（同一设备只回调一次）。
- (void)djiScannerDidDiscoverDevice:(TVUIRLDJIDiscoveredDevice *)device;

@end

#pragma mark - Scanner 主类

@interface TVUIRLDJIDeviceScanner : NSObject

@property (nonatomic, weak, nullable) id<TVUIRLDJIDeviceScannerDelegate> delegate;

/// 当前扫描期内已发现的设备列表（已去重，按发现顺序）
@property (nonatomic, strong, readonly) NSArray<TVUIRLDJIDiscoveredDevice *> *discoveredDevices;

/// 当前是否处于扫描中。stopScanningForDevices 之后会变为 NO。
/// 调用方通常用它来判断是否需要重启扫描，避免重复创建 CBCentralManager。
@property (nonatomic, assign, readonly) BOOL isScanning;

/// 单例。BLE 扫描进程内只允许一个，否则两个 CBCentralManager 会互相挤掉。
+ (instancetype)sharedScanner;

/// 开始扫描。会清空之前的发现列表，并在蓝牙打开后开始扫描所有 BLE 设备。
- (void)startScanningForDevices;

/// 停止扫描并释放底层 CBCentralManager。
- (void)stopScanningForDevices;

@end

NS_ASSUME_NONNULL_END
