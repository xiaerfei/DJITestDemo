//
//  TVUIRLDJIDeviceScanner.m
//  DJIStreamDemo
//

#import "TVUIRLDJIDeviceScanner.h"
#import "TVUIRLDJILog.h"
#import "TVUIRLDJIDeviceModel.h"
#import "TVUIRLDJIMessage.h"  // for TVUIRLDJIHexString

#pragma mark - TVUIRLDJIDiscoveredDevice

@implementation TVUIRLDJIDiscoveredDevice

- (instancetype)initWithPeripheral:(CBPeripheral *)peripheral
                             model:(TVUIRLDJIDeviceModel)model {
    self = [super init];
    if (self) {
        _peripheral = peripheral;
        _model = model;
    }
    return self;
}

@end

#pragma mark - TVUIRLDJIDeviceScanner

@interface TVUIRLDJIDeviceScanner () <CBCentralManagerDelegate>

/// 底层 CoreBluetooth 中央管理器
@property (nonatomic, strong, nullable) CBCentralManager *centralManager;

/// 内部可变的发现列表（外部只能读到 immutable 拷贝）
@property (nonatomic, strong) NSMutableArray<TVUIRLDJIDiscoveredDevice *> *mutableDiscoveredDevices;

@end

@implementation TVUIRLDJIDeviceScanner

#pragma mark - 单例

+ (instancetype)sharedScanner {
    static TVUIRLDJIDeviceScanner *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TVUIRLDJIDeviceScanner alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableDiscoveredDevices = [NSMutableArray array];
    }
    return self;
}

#pragma mark - 公开 API

- (NSArray<TVUIRLDJIDiscoveredDevice *> *)discoveredDevices {
    return [_mutableDiscoveredDevices copy];
}

- (BOOL)isScanning {
    /// stopScanningForDevices 时会把 centralManager 置 nil; 用是否持有 CBCentralManager 作为
    /// "扫描请求是否在线" 的判定 (即使蓝牙还没 poweredOn, 此时也认为扫描已被请求, 避免重复创建)
    return self.centralManager != nil;
}

- (void)startScanningForDevices {
    // 清空上一次扫描结果
    [_mutableDiscoveredDevices removeAllObjects];

    // 创建 CBCentralManager；蓝牙打开后会回调 centralManagerDidUpdateState:
    // 那里再触发实际的 scanForPeripherals.
    // CBCentralManagerOptionShowPowerAlertKey = YES: 当蓝牙处于 OFF 时, 由 iOS 弹出原生
    // "Bluetooth is off" 弹窗引导用户打开 (用户在系统层级可记忆是否再提示), 不需要 app 自行做 UI.
    NSDictionary *options = @{ CBCentralManagerOptionShowPowerAlertKey: @YES };
    self.centralManager = [[CBCentralManager alloc] initWithDelegate:self
                                                               queue:dispatch_get_main_queue()
                                                             options:options];
}

- (void)stopScanningForDevices {
    [self.centralManager stopScan];
    // 释放 manager 让蓝牙状态回到 unknown，避免后台一直占用
    self.centralManager = nil;
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    // 蓝牙打开后才能开始扫描；其它状态（poweredOff/unauthorized 等）什么也不做
    if (central.state == CBManagerStatePoweredOn) {
        // 不指定 services 过滤，因为 DJI 相机的 Service UUID 不固定
        [central scanForPeripheralsWithServices:nil options:nil];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    // ── 1) 拿到广播包里的 Manufacturer Data ──
    NSData *manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if (![manufacturerData isKindOfClass:[NSData class]]) return;

    // ── 2) 看厂商 ID 是否是 DJI ──
    if (![TVUIRLDJIDeviceModelDetector isDjiDevice:manufacturerData]) return;

    // ── 3) 去重：同一外设只通知上层一次 ──
    for (TVUIRLDJIDiscoveredDevice *existing in _mutableDiscoveredDevices) {
        if (existing.peripheral == peripheral) return;
    }

    // ── 4) 解析机型 ──
    TVUIRLDJIDeviceModel model = [TVUIRLDJIDeviceModelDetector modelFromManufacturerData:manufacturerData];
    TVUIRLDJILog(@"dji-scanner: Manufacturer data %@ for peripheral id %@ and model %@",
          TVUIRLDJIHexString(manufacturerData),
          peripheral.identifier.UUIDString,
          TVUIRLDJIDeviceModelDescription(model));

    // ── 5) 入列并通知 delegate ──
    TVUIRLDJIDiscoveredDevice *device = [[TVUIRLDJIDiscoveredDevice alloc] initWithPeripheral:peripheral
                                                                                        model:model];
    [_mutableDiscoveredDevices addObject:device];
    [self.delegate djiScannerDidDiscoverDevice:device];
}

@end
