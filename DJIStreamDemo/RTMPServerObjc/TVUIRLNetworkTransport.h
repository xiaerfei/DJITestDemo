//
//  TVUIRLNetworkTransport.h
//  DJIStreamDemo
//
//  Transport 后端 #1：Apple Network.framework。
//

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import "TVUIRLTransport.h"

NS_ASSUME_NONNULL_BEGIN

@interface TVUIRLNetworkListener : NSObject <TVUIRLTransportListener>
@end

@interface TVUIRLNetworkConnection : NSObject <TVUIRLTransportConnection>
- (instancetype)initWithConnection:(nw_connection_t)connection NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
