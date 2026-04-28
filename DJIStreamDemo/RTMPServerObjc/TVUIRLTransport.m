//
//  TVUIRLTransport.m
//  DJIStreamDemo
//

#import "TVUIRLTransport.h"
#import "TVUIRLNetworkTransport.h"
#import "TVUIRLAsyncSocketTransport.h"

@implementation TVUIRLTransportFactory

+ (id<TVUIRLTransportListener>)listenerForBackend:(TVUIRLTransportBackend)backend {
    switch (backend) {
        case TVUIRLTransportBackendNetwork:
            return [[TVUIRLNetworkListener alloc] init];
        case TVUIRLTransportBackendAsyncSocket:
            return [[TVUIRLAsyncSocketListener alloc] init];
    }
}

+ (NSString *)nameForBackend:(TVUIRLTransportBackend)backend {
    switch (backend) {
        case TVUIRLTransportBackendNetwork:     return @"Network.framework";
        case TVUIRLTransportBackendAsyncSocket: return @"GCDAsyncSocket";
    }
}

@end
