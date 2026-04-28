//
//  TVUIRLBandwidthMeter.m
//  DJIStreamDemo
//

#import "TVUIRLBandwidthMeter.h"

@interface TVUIRLBandwidthMeter ()
@property (nonatomic, readwrite) uint64_t totalBytes;
@property (nonatomic, readwrite) uint64_t latestSpeed;
@property (nonatomic, assign) uint64_t previousTotalBytes;
@property (nonatomic, assign) uint64_t speedChangeRate;
@end

@implementation TVUIRLBandwidthMeter

- (instancetype)init {
    return [self initWithSpeedChangeRate:10];
}

- (instancetype)initWithSpeedChangeRate:(uint64_t)speedChangeRate {
    if (self = [super init]) {
        _speedChangeRate = speedChangeRate;
    }
    return self;
}

- (void)addBytesTransferred:(NSInteger)bytes {
    if (bytes > 0) self.totalBytes += (uint64_t)bytes;
}

- (TVUIRLBandwidthSnapshot)update {
    uint64_t speed = self.totalBytes - self.previousTotalBytes;
    self.latestSpeed = (self.speedChangeRate * speed + (100 - self.speedChangeRate) * self.latestSpeed) / 100;
    self.previousTotalBytes = self.totalBytes;
    TVUIRLBandwidthSnapshot snap = { .total = self.totalBytes, .speed = self.latestSpeed };
    return snap;
}

@end
