//
//  TVUIRLCommandMessage.m
//  DJIStreamDemo
//

#import "TVUIRLCommandMessage.h"
#import "TVUIRLAmfEncoder.h"
#import "TVUIRLAmfDecoder.h"

TVUIRLCommandName const TVUIRLCommandNameConnect       = @"connect";
TVUIRLCommandName const TVUIRLCommandNameClose         = @"close";
TVUIRLCommandName const TVUIRLCommandNameResult        = @"_result";
TVUIRLCommandName const TVUIRLCommandNameError         = @"_error";
TVUIRLCommandName const TVUIRLCommandNamePublish       = @"publish";
TVUIRLCommandName const TVUIRLCommandNameCreateStream  = @"createStream";
TVUIRLCommandName const TVUIRLCommandNameReleaseStream = @"releaseStream";
TVUIRLCommandName const TVUIRLCommandNameFCPublish     = @"FCPublish";
TVUIRLCommandName const TVUIRLCommandNameFCUnpublish   = @"FCUnpublish";
TVUIRLCommandName const TVUIRLCommandNameDeleteStream  = @"deleteStream";
TVUIRLCommandName const TVUIRLCommandNameCloseStream   = @"closeStream";
TVUIRLCommandName const TVUIRLCommandNameOnStatus      = @"onStatus";
TVUIRLCommandName const TVUIRLCommandNameOnFCPublish   = @"onFCPublish";
TVUIRLCommandName const TVUIRLCommandNameUnknown       = @"unknown";

@implementation TVUIRLCommandMessage

- (instancetype)initWithCommandType:(TVUIRLMessageType)commandType {
    if (self = [super initWithType:commandType]) {
        _commandName = TVUIRLCommandNameClose;
        _transactionId = 0;
        _arguments = @[];
    }
    return self;
}

- (instancetype)initWithStreamId:(uint32_t)streamId
                   transactionId:(NSInteger)transactionId
                     commandType:(TVUIRLMessageType)commandType
                     commandName:(TVUIRLCommandName)commandName
                   commandObject:(nullable NSDictionary<NSString *, TVUIRLAmfValue *> *)commandObject
                       arguments:(NSArray<TVUIRLAmfValue *> *)arguments {
    if (self = [super initWithType:commandType]) {
        self.streamId = streamId;
        _transactionId = transactionId;
        _commandName = [commandName copy];
        _commandObject = [commandObject copy];
        _arguments = [arguments copy] ?: @[];
    }
    return self;
}

- (NSData *)buildEncoded {
    TVUIRLAmfEncoder *encoder = [[TVUIRLAmfEncoder alloc] init];
    if (self.type == TVUIRLMessageTypeAmf3Command) {
        [encoder writeUInt8:0];
    }
    [encoder encodeValue:[TVUIRLAmfValue stringValue:self.commandName ?: TVUIRLCommandNameUnknown]];
    [encoder encodeValue:[TVUIRLAmfValue numberValue:(double)self.transactionId]];
    if (self.commandObject) {
        [encoder encodeValue:[TVUIRLAmfValue objectValue:self.commandObject]];
    } else {
        [encoder encodeValue:[TVUIRLAmfValue nullValue]];
    }
    for (TVUIRLAmfValue *arg in self.arguments) {
        [encoder encodeValue:arg];
    }
    return encoder.data;
}

- (void)parseEncoded:(NSData *)data {
    if ((NSInteger)data.length != self.length) return;
    TVUIRLAmfDecoder *decoder = [[TVUIRLAmfDecoder alloc] initWithData:data];
    if (self.type == TVUIRLMessageTypeAmf3Command) {
        decoder.position = 1;
    }
    NSError *error = nil;
    NSString *name = [decoder decodeStringWithError:&error];
    if (error) return;
    self.commandName = name ?: TVUIRLCommandNameUnknown;
    int tid = 0;
    if (![decoder decodeInt:&tid error:&error]) return;
    self.transactionId = tid;
    NSDictionary *obj = [decoder decodeObjectWithError:&error];
    if (error) return;
    self.commandObject = obj;
    NSMutableArray *args = [NSMutableArray array];
    while (decoder.bytesAvailable > 0) {
        TVUIRLAmfValue *v = [decoder decodeWithError:&error];
        if (!v) break;
        [args addObject:v];
    }
    self.arguments = args;
}

@end
