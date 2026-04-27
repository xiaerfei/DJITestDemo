//
//  TVUIRLDJIDevice.h
//  DJIStreamDemo
//
//  DJI 相机 BLE 控制通道的核心：完成连接、配对、配置、启动 / 停止推流。
//
//  为什么有这么多状态：
//    DJI 协议是请求-响应式的，每个命令发出后必须等相机回复，再决定下一步。
//    例如发了 SetupWifi 后必须等回复 0x00 0x00 才能继续 configure / start。
//    因此用一个枚举来跟踪"我目前在等哪个响应"。
//
//  关键 GATT Characteristic：
//    FFF4 ：notify（订阅它就会触发相机配对，订阅成功后内部发出配对消息）
//    FFF5 ：write without response（所有命令都通过这里发送）
//
//  超时保护：
//    - 启动流：60 秒看门狗（startStreamingTimer），超时强制 reset
//    - 停止流：10 秒看门狗（stopStreamingTimer），超时强制 reset
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "TVUIRLDJITypes.h"

NS_ASSUME_NONNULL_BEGIN

@class TVUIRLDJIDevice;

@protocol TVUIRLDJIDeviceDelegate <NSObject>

/// 状态机切换状态时回调（去重过：与上一次相同状态不会重复回调）。
- (void)djiDevice:(TVUIRLDJIDevice *)device didChangeState:(TVUIRLDJIStreamState)state;

@end

@interface TVUIRLDJIDevice : NSObject

@property (nonatomic, weak, nullable) id<TVUIRLDJIDeviceDelegate> delegate;

/// 启动一次完整的"扫描→连接→配对→配 WiFi→配置→启动推流"流程。
/// @param wifiSsid           相机要连接的 WiFi 热点 SSID
/// @param wifiPassword       该 WiFi 密码
/// @param rtmpUrl            相机推流的目标 RTMP URL（一般是手机本地 RTMP 服务地址）
/// @param resolution         推流分辨率
/// @param fps                帧率（25 / 30）
/// @param bitrate            码率（bps）；内部会换算成 kbps
/// @param imageStabilization 图像稳定模式
/// @param deviceId           目标外设的 UUID（来自 Scanner 已发现的 peripheral.identifier）
/// @param model              设备型号（决定走旧协议还是新协议分支）
- (void)startLiveStreamWithWifiSsid:(NSString *)wifiSsid
                       wifiPassword:(NSString *)wifiPassword
                            rtmpUrl:(NSString *)rtmpUrl
                         resolution:(TVUIRLDJIStreamResolution)resolution
                                fps:(NSInteger)fps
                            bitrate:(uint32_t)bitrate
                 imageStabilization:(TVUIRLDJIStreamImageStabilization)imageStabilization
                           deviceId:(NSUUID *)deviceId
                              model:(TVUIRLDJIDeviceModel)model;

/// 主动停止推流（发送 stopStreaming 命令，并启动 10 秒看门狗）。
/// idle 状态下调用是 no-op。
- (void)stopLiveStream;

/// 最近一次相机播报的电量百分比（streaming 状态下相机会定期 push 0x020D00 类型消息，含电量字段）。
/// 还没收到过则返回 nil。
- (nullable NSNumber *)batteryPercentage;

/// 当前状态机所处状态。
- (TVUIRLDJIStreamState)currentState;

@end

NS_ASSUME_NONNULL_END
