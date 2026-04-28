//
//  TVUIRLProtocolMessage.m
//  DJIStreamDemo
//

#import "TVUIRLProtocolMessage.h"

@interface TVUIRLProtocolMessage ()
@property (nonatomic, assign) TVUIRLMessageType type;
@property (nonatomic, copy) NSData *backingEncoded;
@end

@implementation TVUIRLProtocolMessage

- (instancetype)initWithType:(TVUIRLMessageType)type {
    if (self = [super init]) {
        _type = type;
        _backingEncoded = [NSData data];
    }
    return self;
}

- (NSData *)encoded {
    if (self.backingEncoded.length == 0) {
        NSData *built = [self buildEncoded];
        if (built.length > 0) {
            self.backingEncoded = [built copy];
        }
    }
    return self.backingEncoded;
}

- (void)setEncoded:(NSData *)encoded {
    NSData *newValue = encoded ?: [NSData data];
    if ([self.backingEncoded isEqualToData:newValue]) return;
    [self parseEncoded:newValue];
    self.backingEncoded = [newValue copy];
}

- (NSData *)buildEncoded { return [NSData data]; }
- (void)parseEncoded:(NSData *)data { (void)data; }

@end
