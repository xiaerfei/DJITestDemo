//
//  TVUIRLDJIStreamManager.m
//  DJIStreamDemo
//

#import "TVUIRLDJIStreamManager.h"
#import "TVUIRLDJIDevice.h"
#import "TVUIRLDJIDeviceScanner.h"

#import <ifaddrs.h>
#import <netdb.h>
#import <net/if.h>
#import <arpa/inet.h>

#pragma mark - TVUIRLDJIDiscoveredPeripheral

@implementation TVUIRLDJIDiscoveredPeripheral

- (instancetype)initWithPeripheralId:(NSString *)peripheralId
                                name:(NSString *)name
                           modelName:(NSString *)modelName {
    self = [super init];
    if (self) {
        _peripheralId = [peripheralId copy];
        _name = [name copy];
        _modelName = [modelName copy];
    }
    return self;
}

@end

#pragma mark - TVUIRLDJIStreamManager

@interface TVUIRLDJIStreamManager () <TVUIRLDJIDeviceScannerDelegate, TVUIRLDJIDeviceDelegate>

@property (nonatomic, strong) TVUIRLDJIDeviceScanner *scanner;
@property (nonatomic, strong) TVUIRLDJIDevice *device;
@property (nonatomic, strong) NSMutableDictionary<NSString *, TVUIRLDJIDiscoveredDevice *> *discoveredByUUID;

@end

@implementation TVUIRLDJIStreamManager

#pragma mark 单例

+ (instancetype)manager {
    static TVUIRLDJIStreamManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TVUIRLDJIStreamManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _scanner = [TVUIRLDJIDeviceScanner sharedScanner];
        _device = [[TVUIRLDJIDevice alloc] init];
        _discoveredByUUID = [NSMutableDictionary dictionary];

        _scanner.delegate = self;
        _device.delegate = self;
    }
    return self;
}

#pragma mark 扫描

- (void)startScan {
    [_discoveredByUUID removeAllObjects];
    [_scanner startScanningForDevices];
}

- (void)stopScan {
    [_scanner stopScanningForDevices];
}

- (NSArray<TVUIRLDJIDiscoveredPeripheral *> *)discoveredPeripherals {
    NSMutableArray *result = [NSMutableArray array];
    for (TVUIRLDJIDiscoveredDevice *device in _scanner.discoveredDevices) {
        NSString *peripheralId = device.peripheral.identifier.UUIDString;
        NSString *name = device.peripheral.name ?: @"Unknown";
        NSString *modelName = TVUIRLDJIDeviceModelDescription(device.model);
        [result addObject:[[TVUIRLDJIDiscoveredPeripheral alloc] initWithPeripheralId:peripheralId
                                                                                 name:name
                                                                            modelName:modelName]];
    }
    return result;
}

#pragma mark 推流

- (BOOL)startLiveStreamWithPeripheralId:(NSString *)peripheralId
                               wifiSsid:(NSString *)wifiSsid
                           wifiPassword:(NSString *)wifiPassword
                                rtmpUrl:(NSString *)rtmpUrl
                             resolution:(TVUIRLDJIStreamResolution)resolution
                                    fps:(NSInteger)fps
                                bitrate:(uint32_t)bitrate
                     imageStabilization:(TVUIRLDJIStreamImageStabilization)imageStabilization {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:peripheralId];
    TVUIRLDJIDiscoveredDevice *entry = _discoveredByUUID[peripheralId];
    if (!uuid || !entry) {
        NSLog(@"dji-controller: Unknown peripheral %@", peripheralId);
        return NO;
    }

    [self stopScan];

    [_device startLiveStreamWithWifiSsid:wifiSsid
                            wifiPassword:wifiPassword
                                 rtmpUrl:rtmpUrl
                              resolution:resolution
                                     fps:fps
                                 bitrate:bitrate
                      imageStabilization:imageStabilization
                                deviceId:uuid
                                   model:entry.model];
    return YES;
}

- (void)stopLiveStream {
    [_device stopLiveStream];
}

- (nullable NSNumber *)batteryPercentage {
    return [_device batteryPercentage];
}

#pragma mark 局域网辅助

+ (nullable NSString *)currentLanIPv4 {
    NSString *fallback = nil;
    struct ifaddrs *ifaddrPtr = NULL;
    if (getifaddrs(&ifaddrPtr) != 0 || ifaddrPtr == NULL) return nil;

    NSString *result = nil;
    struct ifaddrs *cur = ifaddrPtr;
    while (cur != NULL) {
        unsigned int flags = cur->ifa_flags;
        unsigned int required = (unsigned int)IFF_UP | (unsigned int)IFF_RUNNING;
        if ((flags & required) != required) {
            cur = cur->ifa_next;
            continue;
        }
        if ((flags & (unsigned int)IFF_LOOPBACK) != 0) {
            cur = cur->ifa_next;
            continue;
        }
        struct sockaddr *addr = cur->ifa_addr;
        if (!addr || addr->sa_family != AF_INET) {
            cur = cur->ifa_next;
            continue;
        }

        NSString *name = cur->ifa_name ? [NSString stringWithUTF8String:cur->ifa_name] : @"";
        char host[NI_MAXHOST] = {0};
        if (getnameinfo(addr, addr->sa_len, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) {
            cur = cur->ifa_next;
            continue;
        }
        NSString *ip = [NSString stringWithUTF8String:host];

        if ([name isEqualToString:@"en0"]) {
            result = ip;
            break;
        }
        if ([name hasPrefix:@"bridge"] && fallback == nil) {
            fallback = ip;
        }
        cur = cur->ifa_next;
    }
    freeifaddrs(ifaddrPtr);
    return result ?: fallback;
}

+ (nullable NSString *)localRtmpUrlWithStreamKey:(NSString *)streamKey {
    NSString *ip = [self currentLanIPv4];
    if (!ip) return nil;
    NSString *key = (streamKey.length == 0) ? @"dji" : streamKey;
    return [NSString stringWithFormat:@"rtmp://%@:1935/live/%@", ip, key];
}

#pragma mark - TVUIRLDJIDeviceScannerDelegate

- (void)djiScannerDidDiscoverDevice:(TVUIRLDJIDiscoveredDevice *)device {
    NSString *uuid = device.peripheral.identifier.UUIDString;
    _discoveredByUUID[uuid] = device;

    if ([self.delegate respondsToSelector:@selector(djiStreamManager:didDiscover:)]) {
        TVUIRLDJIDiscoveredPeripheral *payload =
            [[TVUIRLDJIDiscoveredPeripheral alloc] initWithPeripheralId:uuid
                                                                   name:device.peripheral.name ?: @"Unknown"
                                                              modelName:TVUIRLDJIDeviceModelDescription(device.model)];
        [self.delegate djiStreamManager:self didDiscover:payload];
    }
}

#pragma mark - TVUIRLDJIDeviceDelegate

- (void)djiDevice:(TVUIRLDJIDevice *)device didChangeState:(TVUIRLDJIStreamState)state {
    if ([self.delegate respondsToSelector:@selector(djiStreamManager:didChangeState:stateName:)]) {
        [self.delegate djiStreamManager:self
                           didChangeState:state
                                stateName:TVUIRLDJIStreamStateDescription(state)];
    }
}

@end