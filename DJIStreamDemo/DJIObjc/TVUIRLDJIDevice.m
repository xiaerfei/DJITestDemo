//
//  TVUIRLDJIDevice.m
//  DJIStreamDemo
//

#import "TVUIRLDJIDevice.h"
#import "TVUIRLDJIMessage.h"
#import "TVUIRLDJIDeviceMessage.h"
#import "TVUIRLSimpleTimer.h"

#pragma mark - 协议常量
//
// 以下三组常量来自 Moblin 的逆向结果（report.md 第 4.3 节）。
// 同一命令在协议中需要同时填 target / id / type 三个字段才能被相机正确识别。
//

// Transaction ID（事务 ID）：每种命令固定值，相机响应也会复用这个 ID
static const uint16_t kPairTransactionId                  = 0x8092;
static const uint16_t kStopStreamingTransactionId         = 0xEAC8;
static const uint16_t kPreparingToLivestreamTransactionId = 0x8C12;
static const uint16_t kSetupWifiTransactionId             = 0x8C19;
static const uint16_t kStartStreamingTransactionId        = 0x8C2C;
static const uint16_t kConfigureTransactionId             = 0x8C2D;

// Target：消息的目标设备/模块 ID
static const uint16_t kPairTarget                  = 0x0702;
static const uint16_t kStopStreamingTarget         = 0x0802;
static const uint16_t kPreparingToLivestreamTarget = 0x0802;
static const uint16_t kSetupWifiTarget             = 0x0702;
static const uint16_t kConfigureTarget             = 0x0102;
static const uint16_t kStartStreamingTarget        = 0x0802;

// Type：消息类型（24 位）
static const uint32_t kPairType                  = 0x450740;
static const uint32_t kStopStreamingType         = 0x8E0240;
static const uint32_t kPreparingToLivestreamType = 0xE10240;
static const uint32_t kSetupWifiType             = 0x470740;
static const uint32_t kConfigureType             = 0x8E0240;
static const uint32_t kStartStreamingType        = 0x780840;

/// 配对 PIN 码。Moblin 项目使用的固定值（来源："mbln" 单词的简写），
/// DJI 相机不校验 PIN 内容只校验消息格式，所以可以是任意 4 字节字符串。
static NSString * const kPairPinCode = @"mbln";

#pragma mark -

@interface TVUIRLDJIDevice () <CBCentralManagerDelegate, CBPeripheralDelegate>

// ── 业务参数（startLiveStream 调用时填入，后续状态机使用） ──────────
@property (nonatomic, copy, nullable) NSString *wifiSsid;
@property (nonatomic, copy, nullable) NSString *wifiPassword;
@property (nonatomic, copy, nullable) NSString *rtmpUrl;
@property (nonatomic, assign) TVUIRLDJIStreamResolution resolution;
@property (nonatomic, assign) NSInteger fps;
@property (nonatomic, assign) uint32_t bitrate;
@property (nonatomic, assign) TVUIRLDJIStreamImageStabilization imageStabilization;
/// 标记 resolution / imageStabilization 是否被 startLiveStream 真正赋过值
/// （ObjC 枚举无法表示"未设置"，所以加这两个布尔位，相当于 Swift 的 Optional）
@property (nonatomic, assign) BOOL hasResolution;
@property (nonatomic, assign) BOOL hasImageStabilization;
@property (nonatomic, strong, nullable) NSUUID *deviceId;
@property (nonatomic, assign) TVUIRLDJIDeviceModel model;

// ── BLE 资源 ─────────────────────────────────────────────────────
@property (nonatomic, strong, nullable) CBCentralManager *centralManager;
@property (nonatomic, strong, nullable) CBPeripheral *cameraPeripheral;
/// FFF5 写入特征，所有发送命令都通过它
@property (nonatomic, strong, nullable) CBCharacteristic *fff5Characteristic;

// ── 状态机 ─────────────────────────────────────────────────────
@property (nonatomic, assign) TVUIRLDJIStreamState state;
/// 启动流看门狗（60 秒）：从扫描到 streaming 状态期间一直挂着，超时则 reset
@property (nonatomic, strong) TVUIRLSimpleTimer *startStreamingTimer;
/// 停止流看门狗（10 秒）：发出 stopStreaming 后挂着，相机不响应也强制 reset
@property (nonatomic, strong) TVUIRLSimpleTimer *stopStreamingTimer;

// ── 运行时状态 ──────────────────────────────────────────────────
/// 最近一次相机播报的电量百分比
@property (nonatomic, strong, nullable) NSNumber *batteryPercentageNumber;

@end

@implementation TVUIRLDJIDevice

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = TVUIRLDJIStreamStateIdle;
        _fps = 30;
        _bitrate = 6000000;     // 默认 6 Mbps
        _model = TVUIRLDJIDeviceModelUnknown;
        _startStreamingTimer = [[TVUIRLSimpleTimer alloc] initWithQueue:dispatch_get_main_queue()];
        _stopStreamingTimer = [[TVUIRLSimpleTimer alloc] initWithQueue:dispatch_get_main_queue()];
    }
    return self;
}

#pragma mark - 公开 API

- (void)startLiveStreamWithWifiSsid:(NSString *)wifiSsid
                       wifiPassword:(NSString *)wifiPassword
                            rtmpUrl:(NSString *)rtmpUrl
                         resolution:(TVUIRLDJIStreamResolution)resolution
                                fps:(NSInteger)fps
                            bitrate:(uint32_t)bitrate
                 imageStabilization:(TVUIRLDJIStreamImageStabilization)imageStabilization
                           deviceId:(NSUUID *)deviceId
                              model:(TVUIRLDJIDeviceModel)model {
    NSLog(@"dji-device: Start live stream for %@", TVUIRLDJIDeviceModelDescription(model));

    // 保存参数，状态机后续要用
    self.wifiSsid = wifiSsid;
    self.wifiPassword = wifiPassword;
    self.rtmpUrl = rtmpUrl;
    self.resolution = resolution;
    self.hasResolution = YES;
    self.fps = fps;
    self.bitrate = bitrate;
    self.imageStabilization = imageStabilization;
    self.hasImageStabilization = YES;
    self.deviceId = deviceId;
    self.model = model;

    // 重置内部状态（包括停掉所有计时器）
    [self reset];

    // 启动 60 秒看门狗
    [self startStartStreamingTimer];

    // 切换到 discovering 状态，并打开 BLE 中央管理器（扫描在 didUpdateState 中开始）
    [self setState:TVUIRLDJIStreamStateDiscovering];
    self.centralManager = [[CBCentralManager alloc] initWithDelegate:self
                                                               queue:dispatch_get_main_queue()];
}

- (void)stopLiveStream {
    if (self.state == TVUIRLDJIStreamStateIdle) return;

    NSLog(@"dji-device: Stop live stream");
    // 停止启动看门狗，启动停止看门狗（10 秒后强制 reset）
    [self stopStartStreamingTimer];
    [self startStopStreamingTimer];

    // 发送停止流命令，等待相机响应（响应到达后 processStoppingStream 会执行 reset）
    [self sendStopStream];
    [self setState:TVUIRLDJIStreamStateStoppingStream];
}

- (nullable NSNumber *)batteryPercentage {
    return self.batteryPercentageNumber;
}

- (TVUIRLDJIStreamState)currentState {
    return self.state;
}

#pragma mark - 状态/计时辅助

/// 把内部 BLE / 计时器 / 状态全部清掉，回到 idle。
/// 触发场景：startLiveStream 开始时清残留、看门狗超时、stop 完成、连接断开等。
- (void)reset {
    [self stopStartStreamingTimer];
    [self stopStopStreamingTimer];
    self.centralManager = nil;
    self.cameraPeripheral = nil;
    self.fff5Characteristic = nil;
    self.batteryPercentageNumber = nil;
    [self setState:TVUIRLDJIStreamStateIdle];
}

- (void)startStartStreamingTimer {
    __weak typeof(self) weakSelf = self;
    [self.startStreamingTimer startSingleShotWithTimeout:60 handler:^{
        // 60 秒还没进入 streaming，认定失败，强制重置
        [weakSelf reset];
    }];
}

- (void)stopStartStreamingTimer {
    [self.startStreamingTimer stop];
}

- (void)startStopStreamingTimer {
    __weak typeof(self) weakSelf = self;
    [self.stopStreamingTimer startSingleShotWithTimeout:10 handler:^{
        // 10 秒内没收到 stop 响应，强制重置（避免相机失联时一直卡在 stopping 状态）
        [weakSelf reset];
    }];
}

- (void)stopStopStreamingTimer {
    [self.stopStreamingTimer stop];
}

/// 状态切换：相同状态不重复回调，便于 UI 层简化处理。
- (void)setState:(TVUIRLDJIStreamState)state {
    if (state == _state) return;
    NSLog(@"dji-device: State change %@ -> %@",
          TVUIRLDJIStreamStateDescription(_state),
          TVUIRLDJIStreamStateDescription(state));
    _state = state;
    [self.delegate djiDevice:self didChangeState:state];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    // 蓝牙打开后开始扫描所有 BLE 设备（不指定 service 过滤，靠 deviceId 匹配目标）
    if (central.state == CBManagerStatePoweredOn) {
        [self.centralManager scanForPeripheralsWithServices:nil options:nil];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    // 只处理调用方指定的那一台设备（识别码 = deviceId）
    if (![peripheral.identifier isEqual:self.deviceId]) return;

    // 扫到目标后立即停止扫描，发起连接
    [central stopScan];
    self.cameraPeripheral = peripheral;
    peripheral.delegate = self;
    [central connectPeripheral:peripheral options:nil];

    // 重新计时（之前的 60 秒已用了一部分）
    [self startStartStreamingTimer];
    [self setState:TVUIRLDJIStreamStateConnecting];
}

- (void)centralManager:(CBCentralManager *)central
   didFailToConnectPeripheral:(CBPeripheral *)peripheral
                        error:(nullable NSError *)error {
    // 这里不主动处理：60 秒看门狗会兜底
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    // 连上了之后开始发现 service / characteristic
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                  error:(nullable NSError *)error {
    // 连接被断开（用户操作 / 相机重启 / 信号丢失），全部重置
    [self reset];
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverServices:(nullable NSError *)error {
    // 不挑剔 service UUID，全部都查一遍 characteristic
    if (!peripheral.services) return;
    for (CBService *service in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(nullable NSError *)error {
    // 找到的 FFF5 用来写命令（writeWithoutResponse），其它 characteristic 都订阅 notify
    // 订阅 FFF4 的 notify 状态变更会触发后面的配对流程（didUpdateNotificationStateFor）
    CBUUID *fff5Id = [CBUUID UUIDWithString:@"FFF5"];
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:fff5Id]) {
            self.fff5Characteristic = characteristic;
        }
        [peripheral setNotifyValue:YES forCharacteristic:characteristic];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(nullable NSError *)error {
    // 相机通过 notify 推过来的字节流 → 解析成 TVUIRLDJIMessage → 派发给当前状态的 handler
    NSData *value = characteristic.value;
    if (!value) return;

    NSError *parseError = nil;
    TVUIRLDJIMessage *message = [[TVUIRLDJIMessage alloc] initWithData:value error:&parseError];
    if (!message) {
        // CRC 错或长度错的包直接丢，避免误处理
        NSLog(@"dji-device: Discarding corrupt message %@", TVUIRLDJIHexString(value));
        return;
    }

    // 状态机分发：不同状态对收到的消息有不同处理
    switch (self.state) {
        case TVUIRLDJIStreamStateCheckingIfPaired:  [self processCheckingIfPaired:message]; break;
        case TVUIRLDJIStreamStatePairing:           [self processPairing]; break;
        case TVUIRLDJIStreamStateCleaningUp:        [self processCleaningUp:message]; break;
        case TVUIRLDJIStreamStatePreparingStream:   [self processPreparingStream:message]; break;
        case TVUIRLDJIStreamStateSettingUpWifi:     [self processSettingUpWifi:message]; break;
        case TVUIRLDJIStreamStateConfiguring:       [self processConfiguring:message]; break;
        case TVUIRLDJIStreamStateStartingStream:    [self processStartingStream:message]; break;
        case TVUIRLDJIStreamStateStreaming:         [self processStreaming:message]; break;
        case TVUIRLDJIStreamStateStoppingStream:    [self processStoppingStream:message]; break;
        default:
            NSLog(@"dji-device: Received message in unexpected state '%@'",
                  TVUIRLDJIStreamStateDescription(self.state));
            break;
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(nullable NSError *)error {
    // 仅在 connecting 状态、且是 FFF4 的 notify 订阅成功时，触发配对消息发送
    if (self.state != TVUIRLDJIStreamStateConnecting) return;
    CBUUID *fff4Id = [CBUUID UUIDWithString:@"FFF4"];
    if (![characteristic.UUID isEqual:fff4Id]) return;

    // 发送配对消息（带 PIN 码）
    TVUIRLDJIPairMessagePayload *payload = [[TVUIRLDJIPairMessagePayload alloc] initWithPairPinCode:kPairPinCode];
    TVUIRLDJIMessage *request = [[TVUIRLDJIMessage alloc] initWithTarget:kPairTarget
                                                              messageId:kPairTransactionId
                                                                   type:kPairType
                                                                payload:[payload encode]];
    [self writeMessage:request];
    [self setState:TVUIRLDJIStreamStateCheckingIfPaired];
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    // 我们目前不做流控，直接写就行；这里保留实现是为了避免 CoreBluetooth 警告
}

#pragma mark - 状态机 handler
//
// 所有 process*: 方法都遵循一个固定模式：
//   1. 检查 messageId 是否匹配本状态预期的事务 ID（避免被无关消息干扰）
//   2. 根据相机响应内容决定下一步：发出新命令并切换状态
//

/// 发送停止流命令。在 cleanUp 和 stopLiveStream 两处都会用到。
- (void)sendStopStream {
    TVUIRLDJIStopStreamingMessagePayload *payload = [[TVUIRLDJIStopStreamingMessagePayload alloc] init];
    TVUIRLDJIMessage *message = [[TVUIRLDJIMessage alloc] initWithTarget:kStopStreamingTarget
                                                              messageId:kStopStreamingTransactionId
                                                                   type:kStopStreamingType
                                                                payload:[payload encode]];
    [self writeMessage:message];
}

/// checkingIfPaired：刚发出配对消息，看相机回复来判断当前是否已配对。
/// payload == [0x00, 0x01] 表示已配对（直接进入 cleanup 流程）；其它值需要重新走 pairing。
- (void)processCheckingIfPaired:(TVUIRLDJIMessage *)response {
    if (response.messageId != kPairTransactionId) return;
    static const uint8_t expected[] = { 0x00, 0x01 };
    NSData *expectedData = [NSData dataWithBytes:expected length:sizeof(expected)];
    if ([response.payload isEqualToData:expectedData]) {
        // 已配对：跳过 pairing 直接 cleanup
        [self processPairing];
    } else {
        // 未配对：进入 pairing，等下一条消息再做处理
        [self setState:TVUIRLDJIStreamStatePairing];
    }
}

/// pairing：发停止流命令清掉相机残留的推流状态，进入 cleaningUp。
/// 注意：在 pairing 状态下收到任何消息都触发本方法（与 Swift 原版一致）。
- (void)processPairing {
    [self sendStopStream];
    [self setState:TVUIRLDJIStreamStateCleaningUp];
}

/// cleaningUp：相机回复了 stop 响应，开始下发"准备直播"命令。
- (void)processCleaningUp:(TVUIRLDJIMessage *)response {
    if (response.messageId != kStopStreamingTransactionId) return;

    TVUIRLDJIPreparingToLivestreamMessagePayload *payload = [[TVUIRLDJIPreparingToLivestreamMessagePayload alloc] init];
    TVUIRLDJIMessage *message = [[TVUIRLDJIMessage alloc] initWithTarget:kPreparingToLivestreamTarget
                                                              messageId:kPreparingToLivestreamTransactionId
                                                                   type:kPreparingToLivestreamType
                                                                payload:[payload encode]];
    [self writeMessage:message];
    [self setState:TVUIRLDJIStreamStatePreparingStream];
}

/// preparingStream：相机回复了"准备直播"，下发 WiFi 配置。
- (void)processPreparingStream:(TVUIRLDJIMessage *)response {
    if (response.messageId != kPreparingToLivestreamTransactionId) return;
    if (!self.wifiSsid || !self.wifiPassword) return;

    TVUIRLDJISetupWifiMessagePayload *payload = [[TVUIRLDJISetupWifiMessagePayload alloc] initWithSsid:self.wifiSsid
                                                                                              password:self.wifiPassword];
    TVUIRLDJIMessage *message = [[TVUIRLDJIMessage alloc] initWithTarget:kSetupWifiTarget
                                                              messageId:kSetupWifiTransactionId
                                                                   type:kSetupWifiType
                                                                payload:[payload encode]];
    [self writeMessage:message];
    [self setState:TVUIRLDJIStreamStateSettingUpWifi];
}

/// settingUpWifi：根据相机型号决定下一步走 configure 还是直接 startStreaming。
/// payload == [0x00, 0x00] 表示 WiFi 配置成功，否则进入 wifiSetupFailed 错误终态。
- (void)processSettingUpWifi:(TVUIRLDJIMessage *)response {
    if (response.messageId != kSetupWifiTransactionId) return;

    static const uint8_t okBytes[] = { 0x00, 0x00 };
    NSData *expected = [NSData dataWithBytes:okBytes length:sizeof(okBytes)];
    if (![response.payload isEqualToData:expected]) {
        // WiFi 连接失败（密码错？信号差？）
        [self reset];
        [self setState:TVUIRLDJIStreamStateWifiSetupFailed];
        return;
    }

    // 不同机型走不同分支
    switch (self.model) {
        case TVUIRLDJIDeviceModelOsmoAction2:
        case TVUIRLDJIDeviceModelOsmoAction3:
            // OA2 / OA3：跳过 configure，直接启动推流
            [self sendStartStreaming];
            break;

        case TVUIRLDJIDeviceModelOsmoAction4: {
            // OA4：要先发 configure（旧协议字节布局，oa5 = NO）
            if (!self.hasImageStabilization) return;
            TVUIRLDJIConfigureMessagePayload *payload = [[TVUIRLDJIConfigureMessagePayload alloc]
                initWithImageStabilization:self.imageStabilization
                                       oa5:NO];
            TVUIRLDJIMessage *message = [[TVUIRLDJIMessage alloc] initWithTarget:kConfigureTarget
                                                                      messageId:kConfigureTransactionId
                                                                           type:kConfigureType
                                                                        payload:[payload encode]];
            [self writeMessage:message];
            [self setState:TVUIRLDJIStreamStateConfiguring];
            break;
        }

        case TVUIRLDJIDeviceModelOsmoAction5Pro:
        case TVUIRLDJIDeviceModelOsmoAction6:
        case TVUIRLDJIDeviceModelOsmo360: {
            // OA5+ / Osmo 360：要先发 configure（新协议字节布局，oa5 = YES）
            if (!self.hasImageStabilization) return;
            TVUIRLDJIConfigureMessagePayload *payload = [[TVUIRLDJIConfigureMessagePayload alloc]
                initWithImageStabilization:self.imageStabilization
                                       oa5:YES];
            TVUIRLDJIMessage *message = [[TVUIRLDJIMessage alloc] initWithTarget:kConfigureTarget
                                                                      messageId:kConfigureTransactionId
                                                                           type:kConfigureType
                                                                        payload:[payload encode]];
            [self writeMessage:message];
            [self setState:TVUIRLDJIStreamStateConfiguring];
            break;
        }

        case TVUIRLDJIDeviceModelOsmoPocket3:
        case TVUIRLDJIDeviceModelUnknown:
            // Pocket3 / 未知机型：跳过 configure 直接启动
            [self sendStartStreaming];
            break;
    }
}

/// configuring：相机回复了 configure，进入启动推流。
- (void)processConfiguring:(TVUIRLDJIMessage *)response {
    if (response.messageId != kConfigureTransactionId) return;
    [self sendStartStreaming];
}

/// 发送启动推流命令；新协议机型还要追发一个 confirm 包。
- (void)sendStartStreaming {
    if (!self.rtmpUrl || !self.hasResolution) return;

    BOOL oa5 = TVUIRLDJIDeviceModelHasNewProtocol(self.model);
    uint16_t bitrateKbps = (uint16_t)((self.bitrate / 1000) & 0xFFFF);

    // 主推流命令
    TVUIRLDJIStartStreamingMessagePayload *payload = [[TVUIRLDJIStartStreamingMessagePayload alloc]
        initWithRtmpUrl:self.rtmpUrl
             resolution:self.resolution
                    fps:self.fps
            bitrateKbps:bitrateKbps
                    oa5:oa5];
    TVUIRLDJIMessage *message = [[TVUIRLDJIMessage alloc] initWithTarget:kStartStreamingTarget
                                                              messageId:kStartStreamingTransactionId
                                                                   type:kStartStreamingType
                                                                payload:[payload encode]];
    [self writeMessage:message];

    // 新协议机型（OA5 Pro / OA6 / Osmo 360）需要追加 confirm 包，
    // 用 stopStreaming 的 target/id/type，但 payload 是 ConfirmStartStreaming
    // （末字节 0x01 而非 0x02）
    if (oa5) {
        TVUIRLDJIConfirmStartStreamingMessagePayload *confirm = [[TVUIRLDJIConfirmStartStreamingMessagePayload alloc] init];
        TVUIRLDJIMessage *confirmMessage = [[TVUIRLDJIMessage alloc] initWithTarget:kStopStreamingTarget
                                                                         messageId:kStopStreamingTransactionId
                                                                              type:kStopStreamingType
                                                                           payload:[confirm encode]];
        [self writeMessage:confirmMessage];
    }
    [self setState:TVUIRLDJIStreamStateStartingStream];
}

/// startingStream：相机回复了启动推流，进入 streaming（此时相机会真正向 RTMP 服务器推流）。
- (void)processStartingStream:(TVUIRLDJIMessage *)response {
    if (response.messageId != kStartStreamingTransactionId) return;
    [self setState:TVUIRLDJIStreamStateStreaming];
    // 流已经起来了，关掉 60 秒看门狗
    [self stopStartStreamingTimer];
}

/// streaming：稳定推流期间相机会主动 push 状态消息（type=0x020D00 包含电量字段）。
- (void)processStreaming:(TVUIRLDJIMessage *)message {
    if (message.type == 0x020D00) {
        // payload 第 21 字节（index 20）是电量百分比
        if (message.payload.length < 21) return;
        const uint8_t *bytes = (const uint8_t *)message.payload.bytes;
        self.batteryPercentageNumber = @((NSInteger)bytes[20]);
    }
    // 其它类型的状态推送当前不解析
}

/// stoppingStream：相机回复了停止流，可以全局重置。
- (void)processStoppingStream:(TVUIRLDJIMessage *)response {
    if (response.messageId != kStopStreamingTransactionId) return;
    [self reset];
}

#pragma mark - 写入 BLE

/// 用日志记录命令再实际写入。
- (void)writeMessage:(TVUIRLDJIMessage *)message {
    NSLog(@"dji-device: Send %@", [message format]);
    [self writeValue:[message encode]];
}

/// 通过 FFF5 用 writeWithoutResponse 写出去。
/// 没有 FFF5 特征时静默丢弃（不应发生，仅做防御）。
- (void)writeValue:(NSData *)value {
    if (!self.fff5Characteristic) return;
    [self.cameraPeripheral writeValue:value
                    forCharacteristic:self.fff5Characteristic
                                 type:CBCharacteristicWriteWithoutResponse];
}

@end
