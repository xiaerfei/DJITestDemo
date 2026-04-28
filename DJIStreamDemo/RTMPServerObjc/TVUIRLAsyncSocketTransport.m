//
//  TVUIRLAsyncSocketTransport.m
//  DJIStreamDemo
//

#import "TVUIRLAsyncSocketTransport.h"
#import <CocoaAsyncSocket/GCDAsyncSocket.h>
#import <netinet/tcp.h>
#import <netinet/in.h>
#import <sys/socket.h>

#pragma mark - Connection

@interface TVUIRLAsyncSocketConnection : NSObject <TVUIRLTransportConnection, GCDAsyncSocketDelegate>
- (instancetype)initWithSocket:(GCDAsyncSocket *)socket NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface TVUIRLAsyncSocketConnection ()
@property (nonatomic, strong) GCDAsyncSocket *socket;
@property (nonatomic, copy, nullable) void (^receiveHandler)(NSData *data);
@property (nonatomic, copy, nullable) void (^failureHandler)(NSError * _Nullable);
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation TVUIRLAsyncSocketConnection

- (instancetype)initWithSocket:(GCDAsyncSocket *)socket {
    if (self = [super init]) {
        _socket = socket;
    }
    return self;
}

- (void)startWithQueue:(dispatch_queue_t)queue
        receiveHandler:(void (^)(NSData *data))receiveHandler
       failureHandler:(void (^)(NSError * _Nullable error))failureHandler {
    self.receiveHandler = receiveHandler;
    self.failureHandler = failureHandler;
    [self.socket setDelegate:self delegateQueue:queue];
    [self.socket readDataWithTimeout:-1 tag:0];
}

- (void)writeData:(NSData *)data {
    if (data.length == 0 || self.cancelled) return;
    [self.socket writeData:data withTimeout:-1 tag:0];
}

- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    [self.socket disconnect];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    (void)tag;
    if (self.cancelled) return;
    if (data.length > 0 && self.receiveHandler) {
        self.receiveHandler(data);
    }
    [sock readDataWithTimeout:-1 tag:0];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    (void)sock;
    if (self.cancelled) return;
    self.cancelled = YES;
    if (self.failureHandler) self.failureHandler(err);
}

@end

#pragma mark - Listener

@interface TVUIRLAsyncSocketListener () <GCDAsyncSocketDelegate>
@property (nonatomic, strong) GCDAsyncSocket *listenSocket;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) void (^newConnectionHandler)(id<TVUIRLTransportConnection>);
@property (nonatomic, assign) BOOL noDelay;
@end

@implementation TVUIRLAsyncSocketListener

- (BOOL)startOnPort:(uint16_t)port
              queue:(dispatch_queue_t)queue
            noDelay:(BOOL)noDelay
newConnectionHandler:(void (^)(id<TVUIRLTransportConnection> connection))handler
              error:(NSError * _Nullable * _Nullable)error {
    self.queue = queue;
    self.noDelay = noDelay;
    self.newConnectionHandler = handler;
    self.listenSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:queue];
    NSError *acceptError = nil;
    BOOL ok = [self.listenSocket acceptOnPort:port error:&acceptError];
    if (!ok) {
        if (error) *error = acceptError;
        self.listenSocket = nil;
        return NO;
    }
    return YES;
}

- (void)cancel {
    [self.listenSocket setDelegate:nil delegateQueue:NULL];
    [self.listenSocket disconnect];
    self.listenSocket = nil;
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
    (void)sock;
    if (self.noDelay) {
        // 通过 performBlock: 在 socket 自己的 IO 队列上访问底层 fd 设置 TCP_NODELAY
        [newSocket performBlock:^{
            int fd = [newSocket socketFD];
            if (fd >= 0) {
                int yes = 1;
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
            }
        }];
    }
    TVUIRLAsyncSocketConnection *wrapped = [[TVUIRLAsyncSocketConnection alloc] initWithSocket:newSocket];
    if (self.newConnectionHandler) self.newConnectionHandler(wrapped);
}

@end
