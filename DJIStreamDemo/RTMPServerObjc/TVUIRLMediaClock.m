//
//  TVUIRLMediaClock.m
//  DJIStreamDemo
//

#import "TVUIRLMediaClock.h"
#import <math.h>

@interface TVUIRLMediaClock ()
@property (nonatomic, assign) double targetLatency;
@property (nonatomic, assign) double latestAudioPts;
@property (nonatomic, assign) double latestVideoPts;
@property (nonatomic, assign) BOOL hasAudioPts;
@property (nonatomic, assign) BOOL hasVideoPts;
@property (nonatomic, assign) double currentAudioVideoDiff;
@property (nonatomic, assign) double estimatedAudioVideoDiff;
@end

@implementation TVUIRLMediaClock

- (instancetype)initWithTargetLatency:(double)targetLatency {
    if (self = [super init]) {
        _targetLatency = targetLatency;
        _currentAudioVideoDiff = INFINITY;
        _estimatedAudioVideoDiff = 0.0;
    }
    return self;
}

- (void)setLatestAudioPresentationTimeStamp:(double)pts {
    self.latestAudioPts = pts;
    self.hasAudioPts = YES;
}

- (void)setLatestVideoPresentationTimeStamp:(double)pts {
    self.latestVideoPts = pts;
    self.hasVideoPts = YES;
}

- (TVUIRLMediaClockDecision)update {
    TVUIRLMediaClockDecision decision = { .hasUpdate = NO };
    if (!self.hasAudioPts || !self.hasVideoPts) return decision;
    double avDiff = self.latestAudioPts - self.latestVideoPts;
    self.hasAudioPts = NO;
    self.hasVideoPts = NO;
    self.estimatedAudioVideoDiff = self.estimatedAudioVideoDiff * 0.98 + avDiff * 0.02;
    if (fabs(self.estimatedAudioVideoDiff - self.currentAudioVideoDiff) <= 0.1) return decision;
    self.currentAudioVideoDiff = self.estimatedAudioVideoDiff;
    double video = self.targetLatency;
    double audio = self.targetLatency;
    if (avDiff > 0.0) {
        audio += self.currentAudioVideoDiff;
    } else {
        video -= self.currentAudioVideoDiff;
    }
    decision.audioTargetLatency = audio;
    decision.videoTargetLatency = video;
    decision.hasUpdate = YES;
    return decision;
}

@end
