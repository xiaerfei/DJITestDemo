//
//  TVUIRLDJIDeviceMessage.m
//  DJIStreamDemo
//

#import "TVUIRLDJIDeviceMessage.h"
#import "TVUIRLByteIO.h"
#import "TVUIRLDJIMessage.h"  // for TVUIRLDJIPackString / TVUIRLDJIPackUrl

#pragma mark - 配对

@implementation TVUIRLDJIPairMessagePayload

/// 配对消息的固定前缀（33 字节）。
/// 这串 ASCII（"284ae5b8d76b3375a04a6417ad71bea3"）疑似某种"应用 ID" 的字符串字面值，
/// 但 DJI 官方未公开具体含义。逆向工程时直接固定该值即可让相机回复配对响应。
+ (NSData *)staticPrefix {
    static const uint8_t prefix[] = {
        0x20, 0x32, 0x38, 0x34, 0x61, 0x65, 0x35, 0x62,
        0x38, 0x64, 0x37, 0x36, 0x62, 0x33, 0x33, 0x37,
        0x35, 0x61, 0x30, 0x34, 0x61, 0x36, 0x34, 0x31,
        0x37, 0x61, 0x64, 0x37, 0x31, 0x62, 0x65, 0x61,
        0x33,
    };
    return [NSData dataWithBytes:prefix length:sizeof(prefix)];
}

- (instancetype)initWithPairPinCode:(NSString *)pinCode {
    self = [super init];
    if (self) {
        _pairPinCode = [pinCode copy];
    }
    return self;
}

- (NSData *)encode {
    // [固定 33 字节前缀] + [PIN 码（长度前缀 + UTF-8）]
    TVUIRLByteWriter *writer = [[TVUIRLByteWriter alloc] init];
    [writer writeBytes:[TVUIRLDJIPairMessagePayload staticPrefix]];
    [writer writeBytes:TVUIRLDJIPackString(_pairPinCode)];
    return writer.data;
}

@end

#pragma mark - 准备直播

@implementation TVUIRLDJIPreparingToLivestreamMessagePayload

- (NSData *)encode {
    // 单字节常量，没有动态字段
    static const uint8_t bytes[] = { 0x1A };
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

@end

#pragma mark - 配置 WiFi

@implementation TVUIRLDJISetupWifiMessagePayload

- (instancetype)initWithSsid:(NSString *)ssid password:(NSString *)password {
    self = [super init];
    if (self) {
        _wifiSsid = [ssid copy];
        _wifiPassword = [password copy];
    }
    return self;
}

- (NSData *)encode {
    // SSID 和密码各自带 1 字节长度前缀
    TVUIRLByteWriter *writer = [[TVUIRLByteWriter alloc] init];
    [writer writeBytes:TVUIRLDJIPackString(_wifiSsid)];
    [writer writeBytes:TVUIRLDJIPackString(_wifiPassword)];
    return writer.data;
}

@end

#pragma mark - 启动推流

@implementation TVUIRLDJIStartStreamingMessagePayload

- (instancetype)initWithRtmpUrl:(NSString *)rtmpUrl
                     resolution:(TVUIRLDJIStreamResolution)resolution
                            fps:(NSInteger)fps
                    bitrateKbps:(uint16_t)bitrateKbps
                            oa5:(BOOL)oa5 {
    self = [super init];
    if (self) {
        _rtmpUrl = [rtmpUrl copy];
        _resolution = resolution;
        _fps = fps;
        _bitrateKbps = bitrateKbps;
        _oa5 = oa5;
    }
    return self;
}

- (NSData *)encode {
    // ── 把分辨率枚举翻译成协议字节 ──
    uint8_t resolutionByte = 0;
    switch (_resolution) {
        case TVUIRLDJIStreamResolution480p:  resolutionByte = 0x47; break;
        case TVUIRLDJIStreamResolution720p:  resolutionByte = 0x04; break;
        case TVUIRLDJIStreamResolution1080p: resolutionByte = 0x0A; break;
    }

    // ── 帧率字节 ──（25fps=2、30fps=3，其它视为 0 表示默认）
    uint8_t fpsByte = 0;
    switch (_fps) {
        case 25: fpsByte = 2; break;
        case 30: fpsByte = 3; break;
        default: fpsByte = 0; break;
    }

    // ── 协议分支：新机型字节略有不同 ──
    uint8_t byte1 = _oa5 ? 0x2A : 0x2E;

    // 静态填充字节，含义未知，按逆向得到的固定值发送
    static const uint8_t p1[] = { 0x00 };
    static const uint8_t p2[] = { 0x00 };
    static const uint8_t p3[] = { 0x02, 0x00 };
    static const uint8_t p4[] = { 0x00, 0x00, 0x00 };

    // 顺序写入字节
    TVUIRLByteWriter *writer = [[TVUIRLByteWriter alloc] init];
    [writer writeBytes:[NSData dataWithBytes:p1 length:sizeof(p1)]];
    [writer writeUInt8:byte1];
    [writer writeBytes:[NSData dataWithBytes:p2 length:sizeof(p2)]];
    [writer writeUInt8:resolutionByte];
    [writer writeUInt16Le:_bitrateKbps];   // 码率（kbps），小端 16 位
    [writer writeBytes:[NSData dataWithBytes:p3 length:sizeof(p3)]];
    [writer writeUInt8:fpsByte];
    [writer writeBytes:[NSData dataWithBytes:p4 length:sizeof(p4)]];
    [writer writeBytes:TVUIRLDJIPackUrl(_rtmpUrl)];  // 长度+0x00+UTF8
    return writer.data;
}

@end

#pragma mark - 启动推流确认

@implementation TVUIRLDJIConfirmStartStreamingMessagePayload

- (NSData *)encode {
    // 与 StopStreaming 唯一的差别在最后一字节（0x01 = 启动确认）
    static const uint8_t bytes[] = { 0x01, 0x01, 0x1A, 0x00, 0x01, 0x01 };
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

@end

#pragma mark - 停止推流

@implementation TVUIRLDJIStopStreamingMessagePayload

- (NSData *)encode {
    // 与 ConfirmStartStreaming 唯一的差别在最后一字节（0x02 = 停止）
    static const uint8_t bytes[] = { 0x01, 0x01, 0x1A, 0x00, 0x01, 0x02 };
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

@end

#pragma mark - 图像参数

@implementation TVUIRLDJIConfigureMessagePayload

- (instancetype)initWithImageStabilization:(TVUIRLDJIStreamImageStabilization)stabilization
                                       oa5:(BOOL)oa5 {
    self = [super init];
    if (self) {
        _imageStabilization = stabilization;
        _oa5 = oa5;
    }
    return self;
}

- (NSData *)encode {
    // ── 把图像稳定枚举翻译成协议字节 ──
    // 注意 1↔RockSteady、2↔HorizonSteady、3↔RockSteadyPlus、4↔HorizonBalancing —— 顺序与枚举不一致
    uint8_t stabByte = 0;
    switch (_imageStabilization) {
        case TVUIRLDJIStreamImageStabilizationOff:              stabByte = 0; break;
        case TVUIRLDJIStreamImageStabilizationRockSteady:       stabByte = 1; break;
        case TVUIRLDJIStreamImageStabilizationRockSteadyPlus:   stabByte = 3; break;
        case TVUIRLDJIStreamImageStabilizationHorizonBalancing: stabByte = 4; break;
        case TVUIRLDJIStreamImageStabilizationHorizonSteady:    stabByte = 2; break;
    }

    // 协议分支：新机型 byte1 = 0x1A，旧机型 byte1 = 0x08
    uint8_t byte1 = _oa5 ? 0x1A : 0x08;

    static const uint8_t p1[] = { 0x01, 0x01 };
    static const uint8_t p2[] = { 0x00, 0x01 };

    TVUIRLByteWriter *writer = [[TVUIRLByteWriter alloc] init];
    [writer writeBytes:[NSData dataWithBytes:p1 length:sizeof(p1)]];
    [writer writeUInt8:byte1];
    [writer writeBytes:[NSData dataWithBytes:p2 length:sizeof(p2)]];
    [writer writeUInt8:stabByte];
    return writer.data;
}

@end
