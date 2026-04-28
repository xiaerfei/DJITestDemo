//
//  TVUIRLCommandMessage.h
//  DJIStreamDemo
//
//  RTMP AMF0/AMF3 命令消息（type 0x14 / 0x11），用于 connect/createStream/publish 等。
//

#import "TVUIRLProtocolMessage.h"
#import "TVUIRLAmfValue.h"

NS_ASSUME_NONNULL_BEGIN

typedef NSString *TVUIRLCommandName NS_TYPED_ENUM;

extern TVUIRLCommandName const TVUIRLCommandNameConnect;
extern TVUIRLCommandName const TVUIRLCommandNameClose;
extern TVUIRLCommandName const TVUIRLCommandNameResult;
extern TVUIRLCommandName const TVUIRLCommandNameError;
extern TVUIRLCommandName const TVUIRLCommandNamePublish;
extern TVUIRLCommandName const TVUIRLCommandNameCreateStream;
extern TVUIRLCommandName const TVUIRLCommandNameReleaseStream;
extern TVUIRLCommandName const TVUIRLCommandNameFCPublish;
extern TVUIRLCommandName const TVUIRLCommandNameFCUnpublish;
extern TVUIRLCommandName const TVUIRLCommandNameDeleteStream;
extern TVUIRLCommandName const TVUIRLCommandNameCloseStream;
extern TVUIRLCommandName const TVUIRLCommandNameOnStatus;
extern TVUIRLCommandName const TVUIRLCommandNameOnFCPublish;
extern TVUIRLCommandName const TVUIRLCommandNameUnknown;

@interface TVUIRLCommandMessage : TVUIRLProtocolMessage

@property (nonatomic, copy) TVUIRLCommandName commandName;
@property (nonatomic, assign) NSInteger transactionId;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, TVUIRLAmfValue *> *commandObject;
@property (nonatomic, copy) NSArray<TVUIRLAmfValue *> *arguments;

/// 创建用于发送的命令消息。
- (instancetype)initWithStreamId:(uint32_t)streamId
                   transactionId:(NSInteger)transactionId
                     commandType:(TVUIRLMessageType)commandType
                     commandName:(TVUIRLCommandName)commandName
                   commandObject:(nullable NSDictionary<NSString *, TVUIRLAmfValue *> *)commandObject
                       arguments:(NSArray<TVUIRLAmfValue *> *)arguments;

/// 创建空命令消息（用于接收侧）。
- (instancetype)initWithCommandType:(TVUIRLMessageType)commandType;

@end

NS_ASSUME_NONNULL_END
