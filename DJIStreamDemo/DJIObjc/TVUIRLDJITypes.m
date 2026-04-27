//
//  TVUIRLDJITypes.m
//  DJIStreamDemo
//

#import "TVUIRLDJITypes.h"

NSString *TVUIRLDJIStreamStateDescription(TVUIRLDJIStreamState state) {
    switch (state) {
        case TVUIRLDJIStreamStateIdle:             return @"idle";
        case TVUIRLDJIStreamStateDiscovering:      return @"discovering";
        case TVUIRLDJIStreamStateConnecting:       return @"connecting";
        case TVUIRLDJIStreamStateCheckingIfPaired: return @"checkingIfPaired";
        case TVUIRLDJIStreamStatePairing:          return @"pairing";
        case TVUIRLDJIStreamStateCleaningUp:       return @"cleaningUp";
        case TVUIRLDJIStreamStatePreparingStream:  return @"preparingStream";
        case TVUIRLDJIStreamStateSettingUpWifi:    return @"settingUpWifi";
        case TVUIRLDJIStreamStateWifiSetupFailed:  return @"wifiSetupFailed";
        case TVUIRLDJIStreamStateConfiguring:      return @"configuring";
        case TVUIRLDJIStreamStateStartingStream:   return @"startingStream";
        case TVUIRLDJIStreamStateStreaming:        return @"streaming";
        case TVUIRLDJIStreamStateStoppingStream:   return @"stoppingStream";
    }
    return @"unknown";
}

NSString *TVUIRLDJIDeviceModelDescription(TVUIRLDJIDeviceModel model) {
    switch (model) {
        case TVUIRLDJIDeviceModelOsmoAction2:    return @"osmoAction2";
        case TVUIRLDJIDeviceModelOsmoAction3:    return @"osmoAction3";
        case TVUIRLDJIDeviceModelOsmoAction4:    return @"osmoAction4";
        case TVUIRLDJIDeviceModelOsmoAction5Pro: return @"osmoAction5Pro";
        case TVUIRLDJIDeviceModelOsmoAction6:    return @"osmoAction6";
        case TVUIRLDJIDeviceModelOsmoPocket3:    return @"osmoPocket3";
        case TVUIRLDJIDeviceModelOsmo360:        return @"osmo360";
        case TVUIRLDJIDeviceModelUnknown:        return @"unknown";
    }
    return @"unknown";
}

BOOL TVUIRLDJIDeviceModelHasNewProtocol(TVUIRLDJIDeviceModel model) {
    // OA5 Pro 之后推出的机型使用新协议：
    //   1) configure 消息 byte1 从 0x08 变为 0x1A
    //   2) start streaming 消息 byte1 从 0x2E 变为 0x2A
    //   3) 启动推流后还需追发一个 0x01 0x01 0x1A 0x00 0x01 0x01 的 confirm 包
    switch (model) {
        case TVUIRLDJIDeviceModelOsmoAction5Pro:
        case TVUIRLDJIDeviceModelOsmoAction6:
        case TVUIRLDJIDeviceModelOsmo360:
            return YES;
        default:
            return NO;
    }
}
