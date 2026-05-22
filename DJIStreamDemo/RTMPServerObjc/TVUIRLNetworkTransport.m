//
//  TVUIRLNetworkTransport.m
//  DJIStreamDemo
//

#import "TVUIRLNetworkTransport.h"
#import "TVUIRLDJILog.h"

#pragma mark - Connection

@interface TVUIRLNetworkConnection ()
// nw_connection_t / nw_listener_t 在 ARC 下都是 Objective-C 对象（NW_OBJECT_DECL 展开
// 为 NSObject<OS_nw_*> *）。必须用 strong，否则 ARC 不 retain，完全靠 nw framework
// 内部的引用维持；一旦时序错位（例如调用方忘记 stop() 直接 release server），
// dealloc 里调 nw_connection_cancel(_connection) 会踩到已释放对象 → 崩溃。
@property (nonatomic, strong) nw_connection_t connection;
@property (nonatomic, copy, nullable) void (^receiveHandler)(NSData *data);
@property (nonatomic, copy, nullable) void (^failureHandler)(NSError * _Nullable);
@property (nonatomic, assign) BOOL cancelled;
/// nw_connection_receive 的 min_byte_count。握手期默认 1（每包都回调，
/// 保证 1537/1536 字节的握手消息不被卡住），握手完成后由上层调成 8192
/// 进入批量化模式，把回调频率从 ~250-400/s 降到 ~30-80/s。
@property (nonatomic, assign) uint32_t receiveBatchMinBytes;
/// 每秒回调统计
@property (nonatomic, assign) NSUInteger statsCallbackCount;
@property (nonatomic, assign) NSUInteger statsBytesCount;
@property (nonatomic, assign) CFAbsoluteTime statsWindowStart;
@end

@implementation TVUIRLNetworkConnection

- (instancetype)initWithConnection:(nw_connection_t)connection {
    if (self = [super init]) {
        _connection = connection;
        _receiveBatchMinBytes = 1;
        _statsWindowStart = CFAbsoluteTimeGetCurrent();
    }
    return self;
}

- (void)setReceiveBatchMinBytes:(uint32_t)minBytes {
    // 下一次 receiveLoop 调用会读取新值，无需重启当前 receive。
    _receiveBatchMinBytes = MAX((uint32_t)1, minBytes);
}

- (void)startWithQueue:(dispatch_queue_t)queue
        receiveHandler:(void (^)(NSData *data))receiveHandler
       failureHandler:(void (^)(NSError * _Nullable error))failureHandler {
    self.receiveHandler = receiveHandler;
    self.failureHandler = failureHandler;
    nw_connection_set_queue(self.connection, queue);
    nw_connection_set_state_changed_handler(self.connection, ^(nw_connection_state_t state, nw_error_t  _Nullable error) {
        (void)state; (void)error;
    });
    nw_connection_start(self.connection);
    [self receiveLoop];
}

- (void)receiveLoop {
    if (self.cancelled) return;
    __weak typeof(self) weakSelf = self;
    uint32_t minBytes = _receiveBatchMinBytes ?: 1;
    nw_connection_receive(self.connection, minBytes, 131072,
        ^(dispatch_data_t  _Nullable content, nw_content_context_t  _Nullable ctx, bool isComplete, nw_error_t  _Nullable error) {
        (void)ctx; (void)isComplete;
        typeof(self) self_ = weakSelf;
        if (!self_ || self_.cancelled) return;
        if (content && dispatch_data_get_size(content) > 0) {
            NSData *data = (NSData *)content;
            self_.statsCallbackCount += 1;
            self_.statsBytesCount += data.length;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            CFAbsoluteTime elapsed = now - self_.statsWindowStart;
            if (elapsed >= 1.0) {
                TVUIRLDJILog(@"[nw_recv] callbacks=%lu  bytes=%lu  (%.1f KB/s)",
                             (unsigned long)self_.statsCallbackCount,
                             (unsigned long)self_.statsBytesCount,
                             self_.statsBytesCount / elapsed / 1024.0);
                self_.statsCallbackCount = 0;
                self_.statsBytesCount = 0;
                self_.statsWindowStart = now;
            }
            if (self_.receiveHandler) self_.receiveHandler(data);
            [self_ receiveLoop];
        }
        if (error) {
            int code = nw_error_get_error_code(error);
            NSError *nserr = [NSError errorWithDomain:@"TVUIRLNetworkTransport"
                                                 code:code
                                             userInfo:@{NSLocalizedDescriptionKey: @"Network framework receive error"}];
            if (self_.failureHandler) self_.failureHandler(nserr);
        } else if (isComplete && (!content || dispatch_data_get_size(content) == 0)) {
            if (self_.failureHandler) self_.failureHandler(nil);
        }
    });
}

- (void)writeData:(NSData *)data {
    if (data.length == 0 || self.cancelled) return;
    dispatch_data_t dd = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(self.connection, dd, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
        ^(nw_error_t  _Nullable error) {
        (void)error;
    });
}

- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    nw_connection_cancel(self.connection);
}

- (void)dealloc {
    // _connection 已经是 strong，ARC 会自动 release。这里只是兜底：如果调用方
    // 释放本对象之前没调 cancel，主动取消一次，让 nw framework 走完正常的状态
    // 转换（释放 fd / mbuf / channel 等资源），而不是依赖 ARC 析构时的隐式清理。
    if (_connection && !_cancelled) {
        _cancelled = YES;
        nw_connection_cancel(_connection);
    }
}

@end

#pragma mark - Listener

@interface TVUIRLNetworkListener ()
// 同样：nw_listener_t 是 ARC 对象，必须 strong，否则依赖 nw framework 内部 retain
// 维持存活，存在悬挂指针风险。
@property (nonatomic, strong) nw_listener_t listener;
@property (nonatomic, copy, nullable) void (^newConnectionHandler)(id<TVUIRLTransportConnection>);
@end

@implementation TVUIRLNetworkListener

- (BOOL)startOnPort:(uint16_t)port
              queue:(dispatch_queue_t)queue
            noDelay:(BOOL)noDelay
newConnectionHandler:(void (^)(id<TVUIRLTransportConnection> connection))handler
              error:(NSError * _Nullable * _Nullable)error {
    self.newConnectionHandler = handler;

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );
    nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(params);
    nw_protocol_options_t tcpOpts = nw_protocol_stack_copy_transport_protocol(stack);
    if (tcpOpts) {
        nw_tcp_options_set_no_delay(tcpOpts, noDelay);
    }
    nw_parameters_set_reuse_local_address(params, true);

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", (unsigned)port);
    nw_endpoint_t endpoint = nw_endpoint_create_host("0.0.0.0", portStr);
    nw_parameters_set_local_endpoint(params, endpoint);

    nw_listener_t listener = nw_listener_create(params);
    if (!listener) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVUIRLNetworkTransport"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"failed to create nw_listener"}];
        }
        return NO;
    }
    self.listener = listener;
    __weak typeof(self) weakSelf = self;
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t  _Nullable err) {
        if (state == nw_listener_state_failed) {
            TVUIRLDJILog(@"rtmp-server[Network]: listener failed: %@", err);
        }
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        typeof(self) self_ = weakSelf;
        if (!self_ || !self_.newConnectionHandler) return;
        TVUIRLNetworkConnection *wrapped = [[TVUIRLNetworkConnection alloc] initWithConnection:connection];
        self_.newConnectionHandler(wrapped);
    });
    nw_listener_set_queue(listener, queue);
    nw_listener_start(listener);
    return YES;
}

- (void)cancel {
    if (self.listener) {
        nw_listener_set_state_changed_handler(self.listener, NULL);
        nw_listener_set_new_connection_handler(self.listener, NULL);
        nw_listener_cancel(self.listener);
        self.listener = NULL;
    }
}

@end
