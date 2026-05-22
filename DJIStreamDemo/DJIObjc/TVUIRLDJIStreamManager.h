//
//  TVUIRLDJIStreamManager.h
//  DJIStreamDemo
//
//  DJI 集成模块对外的唯一入口：业务层只需要使用本类。
//
//  内部组合：
//    - TVUIRLDJIDeviceScanner：扫描周围 DJI 相机
//    - TVUIRLDJIDevice       ：BLE 状态机，控制单台相机的推流流程
//
//  典型使用流程：
//    1. [manager setDelegate:self]
//    2. [manager startScan]
//    3. 收到 didDiscover 回调 → 把发现的相机展示给用户选择
//    4. 用户选好 + 输入 WiFi 信息 → [manager startLiveStreamWithPeripheralId:...]
//    5. 监听 didChangeState 回调更新 UI 状态
//    6. 用户停止时 → [manager stopLiveStream]
//

#import <Foundation/Foundation.h>
#import "TVUIRLDJITypes.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 已发现外设的 DTO

@interface TVUIRLDJIDiscoveredPeripheral : NSObject

@property (nonatomic, copy, readonly) NSString *peripheralId;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *modelName;

- (instancetype)initWithPeripheralId:(NSString *)peripheralId
                                name:(NSString *)name
                           modelName:(NSString *)modelName;

@end

#pragma mark - 委托

@class TVUIRLDJIStreamManager;

@protocol TVUIRLDJIStreamManagerDelegate <NSObject>
@optional

- (void)djiStreamManager:(TVUIRLDJIStreamManager *)manager
            didDiscover:(TVUIRLDJIDiscoveredPeripheral *)peripheral;

- (void)djiStreamManager:(TVUIRLDJIStreamManager *)manager
          didChangeState:(TVUIRLDJIStreamState)state
               stateName:(NSString *)stateName;

@end

#pragma mark - 控制器主类

@interface TVUIRLDJIStreamManager : NSObject

@property (nonatomic, weak, nullable) id<TVUIRLDJIStreamManagerDelegate> delegate;

+ (instancetype)manager;

#pragma mark 观察者(可与主 delegate 并存, 弱引用)

/// 注册一个事件观察者. 与 delegate 不同, 同时存在多个观察者也不会互相覆盖,
/// 适用于 ControlBS 之外需要监听 BLE 事件的模块(例如 Module 转发 TVUIRLEvent).
- (void)addObserver:(id<TVUIRLDJIStreamManagerDelegate>)observer;
- (void)removeObserver:(id<TVUIRLDJIStreamManagerDelegate>)observer;

#pragma mark 扫描

- (void)startScan;
- (void)stopScan;
- (NSArray<TVUIRLDJIDiscoveredPeripheral *> *)discoveredPeripherals;

/// 当前 BLE 扫描是否在线. 用于判断是否需要重启扫描.
- (BOOL)isScanning;

#pragma mark 推流

- (BOOL)startLiveStreamWithPeripheralId:(NSString *)peripheralId
                               wifiSsid:(NSString *)wifiSsid
                           wifiPassword:(NSString *)wifiPassword
                                rtmpUrl:(NSString *)rtmpUrl
                             resolution:(TVUIRLDJIStreamResolution)resolution
                                    fps:(NSInteger)fps
                                bitrate:(uint32_t)bitrate
                     imageStabilization:(TVUIRLDJIStreamImageStabilization)imageStabilization;

- (void)stopLiveStream;
- (nullable NSNumber *)batteryPercentage;

#pragma mark 局域网辅助

+ (nullable NSString *)currentLanIPv4;
+ (nullable NSString *)localRtmpUrlWithStreamKey:(NSString *)streamKey;

@end

NS_ASSUME_NONNULL_END