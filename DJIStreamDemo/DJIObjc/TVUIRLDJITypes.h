//
//  TVUIRLDJITypes.h
//  DJIStreamDemo
//
//  本文件集中定义所有 DJI 集成模块对外可见的枚举类型。
//  所有 enum 使用 NS_ENUM 形式，方便 ObjC / Swift 双向访问。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 推流状态机

/// 整个 BLE 控制+推流过程的状态机枚举。
///
/// 典型流转（成功路径）：
///   idle → discovering → connecting → checkingIfPaired
///        → pairing → cleaningUp → preparingStream
///        → settingUpWifi → configuring → startingStream → streaming
///
/// 异常路径：
///   - settingUpWifi 失败 → wifiSetupFailed → idle
///   - 用户主动停止：streaming → stoppingStream → idle
///   - 任意阶段超时（看门狗触发）→ idle
///
/// 状态变更会通过 TVUIRLDJIStreamManagerDelegate 回调上层。
typedef NS_ENUM(NSInteger, TVUIRLDJIStreamState) {
    TVUIRLDJIStreamStateIdle = 0,             ///< 空闲（初始状态 / 重置后）
    TVUIRLDJIStreamStateDiscovering,          ///< 正在扫描目标外设
    TVUIRLDJIStreamStateConnecting,           ///< 已发起 BLE 连接，等待连上
    TVUIRLDJIStreamStateCheckingIfPaired,     ///< 已发出配对消息，等待响应
    TVUIRLDJIStreamStatePairing,              ///< 配对中（实际只是过渡状态）
    TVUIRLDJIStreamStateCleaningUp,           ///< 发停止流命令清理相机残留状态
    TVUIRLDJIStreamStatePreparingStream,      ///< 通知相机进入直播准备
    TVUIRLDJIStreamStateSettingUpWifi,        ///< 正在向相机下发 WiFi 配置
    TVUIRLDJIStreamStateWifiSetupFailed,      ///< WiFi 配置失败（错误终态）
    TVUIRLDJIStreamStateConfiguring,          ///< 正在下发图像稳定等参数
    TVUIRLDJIStreamStateStartingStream,       ///< 已发启动推流命令，等待响应
    TVUIRLDJIStreamStateStreaming,            ///< 推流中（成功终态）
    TVUIRLDJIStreamStateStoppingStream,       ///< 正在停止推流
};

#pragma mark - 推流参数枚举

/// 推流分辨率。注意这里只列出 DJI 协议支持的三档，
/// 在 TVUIRLDJIStartStreamingMessagePayload 内部映射到协议字节值（0x47/0x04/0x0A）。
typedef NS_ENUM(NSInteger, TVUIRLDJIStreamResolution) {
    TVUIRLDJIStreamResolution480p = 0,
    TVUIRLDJIStreamResolution720p,
    TVUIRLDJIStreamResolution1080p,
};

/// 图像稳定模式。映射到 DJI 协议的 0/1/2/3/4 字节值。
typedef NS_ENUM(NSInteger, TVUIRLDJIStreamImageStabilization) {
    TVUIRLDJIStreamImageStabilizationOff = 0,        ///< 关闭
    TVUIRLDJIStreamImageStabilizationRockSteady,     ///< RockSteady
    TVUIRLDJIStreamImageStabilizationRockSteadyPlus, ///< RockSteady+
    TVUIRLDJIStreamImageStabilizationHorizonBalancing, ///< 水平平衡
    TVUIRLDJIStreamImageStabilizationHorizonSteady,  ///< 水平锁定
};

#pragma mark - 设备型号

/// DJI 设备型号枚举。型号识别码来自 BLE 广播包的 Manufacturer Data 字节 2-3。
/// 不同型号在配置阶段的协议分支不同，详见 DjiDevice 中的 processSettingUpWifi 实现。
typedef NS_ENUM(NSInteger, TVUIRLDJIDeviceModel) {
    TVUIRLDJIDeviceModelUnknown = 0,        ///< 未知型号（兜底）
    TVUIRLDJIDeviceModelOsmoAction2,        ///< Osmo Action 2 — 0x10 0x00
    TVUIRLDJIDeviceModelOsmoAction3,        ///< Osmo Action 3 — 0x12 0x00
    TVUIRLDJIDeviceModelOsmoAction4,        ///< Osmo Action 4 — 0x14 0x00
    TVUIRLDJIDeviceModelOsmoAction5Pro,     ///< Osmo Action 5 Pro — 0x15 0x00（新协议）
    TVUIRLDJIDeviceModelOsmoAction6,        ///< Osmo Action 6 — 0x18 0x00（新协议）
    TVUIRLDJIDeviceModelOsmoPocket3,        ///< Osmo Pocket 3 — 0x20 0x00
    TVUIRLDJIDeviceModelOsmo360,            ///< Osmo 360 — 0x17 0x00（新协议）
};

#pragma mark - 工具函数

/// 把 TVUIRLDJIStreamState 转成可读字符串（用于日志/UI 展示）。
FOUNDATION_EXPORT NSString *TVUIRLDJIStreamStateDescription(TVUIRLDJIStreamState state);

/// 把 TVUIRLDJIDeviceModel 转成可读字符串。
FOUNDATION_EXPORT NSString *TVUIRLDJIDeviceModelDescription(TVUIRLDJIDeviceModel model);

/// 判断指定型号是否使用"新协议"。
/// 新协议机型（OA5 Pro / OA6 / Osmo 360）的启动推流命令需要额外发送一个 confirm 包，
/// 且 configure 消息和 start streaming 消息的某些字节值不同。
FOUNDATION_EXPORT BOOL TVUIRLDJIDeviceModelHasNewProtocol(TVUIRLDJIDeviceModel model);

NS_ASSUME_NONNULL_END
