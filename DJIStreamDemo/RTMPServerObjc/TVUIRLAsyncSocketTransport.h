//
//  TVUIRLAsyncSocketTransport.h
//  DJIStreamDemo
//
//  Transport 后端 #2：CocoaAsyncSocket / GCDAsyncSocket。
//

#import <Foundation/Foundation.h>
#import "TVUIRLTransport.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLAsyncSocketListener : NSObject <TVUIRLTransportListener>
@end

NS_ASSUME_NONNULL_END
