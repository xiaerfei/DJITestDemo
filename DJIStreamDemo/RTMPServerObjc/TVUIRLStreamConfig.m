//
//  TVUIRLStreamConfig.m
//  DJIStreamDemo
//

#import "TVUIRLStreamConfig.h"

@implementation TVUIRLStreamProfile

- (instancetype)initWithStreamKey:(NSString *)streamKey {
    return [self initWithStreamKey:streamKey latency:2000 uuid:[NSUUID UUID]];
}

- (instancetype)initWithStreamKey:(NSString *)streamKey latency:(int32_t)latency {
    return [self initWithStreamKey:streamKey latency:latency uuid:[NSUUID UUID]];
}

- (instancetype)initWithStreamKey:(NSString *)streamKey latency:(int32_t)latency uuid:(NSUUID *)uuid {
    if (self = [super init]) {
        _streamKey = [streamKey copy];
        _latency = latency;
        _uuid = [uuid copy];
    }
    return self;
}

- (double)latencySeconds { return (double)self.latency / 1000.0; }

@end

@implementation TVUIRLStreamConfig

- (instancetype)init {
    return [self initWithPort:1935 streams:@[] noDelay:YES];
}

- (instancetype)initWithPort:(uint16_t)port streams:(NSArray<TVUIRLStreamProfile *> *)streams noDelay:(BOOL)noDelay {
    if (self = [super init]) {
        _port = port;
        _streams = [streams copy];
        _noDelay = noDelay;
    }
    return self;
}

@end
