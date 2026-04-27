//
//  TVUIRLDJIDeviceMessage.h
//  DJIStreamDemo
//
//  DJI BLE 协议中各种"业务命令"的载荷（Payload）类。
//
//  与 TVUIRLDJIMessage 的关系：
//    - TVUIRLDJIMessage 是协议帧（含起始字节、CRC、target/id/type 等）
//    - 这里每个 Payload 类只负责生成 **载荷字节**，由调用方再用合适的 target/id/type 包装
//
//  涉及的命令（按状态机执行顺序）：
//    1. Pair                      ← 配对 (transactionId 0x8092)
//    2. PreparingToLivestream     ← 准备直播 (0x8C12)
//    3. SetupWifi                 ← 配置 WiFi (0x8C19)
//    4. Configure                 ← 图像稳定等参数 (0x8C2D)
//    5. StartStreaming            ← 启动推流 (0x8C2C)
//    6. ConfirmStartStreaming     ← OA5 系列额外的确认包
//    7. StopStreaming             ← 停止推流 (0xEAC8)
//

#import <Foundation/Foundation.h>
#import "TVUIRLDJITypes.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 配对

/// 配对消息载荷。
/// 内容固定前缀（33 字节，疑似某种"应用 ID" 的 ASCII 字符）+ 用户提供的 PIN 码（带长度前缀）。
/// 工程内 PIN 码硬编码为 "mbln"（沿用 Moblin 上的命名习惯，避免和官方 App 冲突）。
@interface TVUIRLDJIPairMessagePayload : NSObject

@property (nonatomic, copy) NSString *pairPinCode;

- (instancetype)initWithPairPinCode:(NSString *)pinCode;
- (NSData *)encode;

@end

#pragma mark - 准备直播

/// 通知相机进入"直播准备"状态。载荷固定为单字节 0x1A，无可变字段。
@interface TVUIRLDJIPreparingToLivestreamMessagePayload : NSObject
- (NSData *)encode;
@end

#pragma mark - 配置 WiFi

/// 把 SSID 和密码下发给相机，相机随后会去连这个 WiFi 热点。
/// SSID / 密码各自以 1 字节长度前缀的 UTF-8 字符串编码。
@interface TVUIRLDJISetupWifiMessagePayload : NSObject

@property (nonatomic, copy) NSString *wifiSsid;
@property (nonatomic, copy) NSString *wifiPassword;

- (instancetype)initWithSsid:(NSString *)ssid password:(NSString *)password;
- (NSData *)encode;

@end

#pragma mark - 启动推流

/// 启动推流命令，含 RTMP URL、分辨率、帧率、码率等配置。
///
/// 字节布局（Moblin 逆向得出）：
///   00          固定 0x00
///   byte1       0x2E（旧协议）/ 0x2A（新协议 OA5+）
///   00          固定 0x00
///   resolution  0x47=480p, 0x04=720p, 0x0A=1080p
///   bitrate     UInt16 LE，单位 kbps
///   02 00       固定
///   fps         0x02=25fps, 0x03=30fps
///   00 00 00    固定
///   url         长度+0x00+UTF8 字节
@interface TVUIRLDJIStartStreamingMessagePayload : NSObject

@property (nonatomic, copy) NSString *rtmpUrl;
@property (nonatomic, assign) TVUIRLDJIStreamResolution resolution;
@property (nonatomic, assign) NSInteger fps;
@property (nonatomic, assign) uint16_t bitrateKbps;
/// YES = 使用新协议（OA5 Pro / OA6 / Osmo 360）
@property (nonatomic, assign) BOOL oa5;

- (instancetype)initWithRtmpUrl:(NSString *)rtmpUrl
                     resolution:(TVUIRLDJIStreamResolution)resolution
                            fps:(NSInteger)fps
                    bitrateKbps:(uint16_t)bitrateKbps
                            oa5:(BOOL)oa5;

- (NSData *)encode;

@end

#pragma mark - 启动推流确认（仅新协议机型）

/// OA5 Pro/OA6/Osmo 360 在收到 StartStreaming 之后，
/// 还需要再发一个 6 字节的 confirm 包（与 stopStreaming 包结构相似，最后一字节 0x01）相机才会真正推流。
@interface TVUIRLDJIConfirmStartStreamingMessagePayload : NSObject
- (NSData *)encode;
@end

#pragma mark - 停止推流

/// 停止推流命令，载荷固定为 6 字节。
/// 注意它与 ConfirmStartStreaming 的差异仅在最后一字节（0x02 = 停止 / 0x01 = 启动确认）。
@interface TVUIRLDJIStopStreamingMessagePayload : NSObject
- (NSData *)encode;
@end

#pragma mark - 图像参数配置

/// 给相机下发图像稳定模式。OA4 / OA5+ 的字节值不同。
@interface TVUIRLDJIConfigureMessagePayload : NSObject

@property (nonatomic, assign) TVUIRLDJIStreamImageStabilization imageStabilization;
/// YES = OA5+ 新协议字节布局
@property (nonatomic, assign) BOOL oa5;

- (instancetype)initWithImageStabilization:(TVUIRLDJIStreamImageStabilization)stabilization
                                       oa5:(BOOL)oa5;
- (NSData *)encode;

@end

NS_ASSUME_NONNULL_END
