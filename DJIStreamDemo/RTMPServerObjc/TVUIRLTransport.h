//
//  TVUIRLTransport.h
//  DJIStreamDemo
//
//  TCP transport 抽象。两个后端实现：
//    1. Network.framework (nw_listener_t / nw_connection_t)
//    2. GCDAsyncSocket (CocoaAsyncSocket)
//
//  StreamingServer 和 StreamConnection 通过协议交互，不直接绑定具体 socket 库。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TVUIRLTransportBackend) {
    TVUIRLTransportBackendNetwork,        // Network.framework
    TVUIRLTransportBackendAsyncSocket,    // CocoaAsyncSocket / GCDAsyncSocket
};

/// 单个 TCP 连接的字节级抽象。所有回调在 startWithQueue: 指定的队列上调度。
@protocol TVUIRLTransportConnection <NSObject>

@required

/// 启动连接：注册接收/失败回调。每收到一段字节就调用一次 receiveHandler。
/// 出错或对端关闭时 failureHandler 触发一次。
- (void)startWithQueue:(dispatch_queue_t)queue
        receiveHandler:(void (^)(NSData *data))receiveHandler
       failureHandler:(void (^)(NSError * _Nullable error))failureHandler;

/// 发送数据。底层保证按调用顺序写出。
- (void)writeData:(NSData *)data;

/// 主动断开。
- (void)cancel;

@optional

/// 配置接收回调的最小批量字节数。RTMP 握手期保持默认 1（保证 1537/1536 字节
/// 的小消息能立即触发），握手完成进入媒体流阶段后可调大（建议 8192），让
/// nw framework 在内核侧累计足够数据再一次性回调，显著降低用户态回调频率
/// 与配套的 dispatch / msgSend 开销。
///
/// AsyncSocket backend 没有等价语义，可不实现此方法（caller 用
/// respondsToSelector: 检查）。
- (void)setReceiveBatchMinBytes:(uint32_t)minBytes;

@end

/// TCP listener 抽象。
@protocol TVUIRLTransportListener <NSObject>

- (BOOL)startOnPort:(uint16_t)port
              queue:(dispatch_queue_t)queue
            noDelay:(BOOL)noDelay
newConnectionHandler:(void (^)(id<TVUIRLTransportConnection> connection))handler
              error:(NSError * _Nullable * _Nullable)error;

- (void)cancel;

@end

/// 工厂：根据 backend 返回对应实现。
@interface TVUIRLTransportFactory : NSObject

+ (id<TVUIRLTransportListener>)listenerForBackend:(TVUIRLTransportBackend)backend;
+ (NSString *)nameForBackend:(TVUIRLTransportBackend)backend;

@end

NS_ASSUME_NONNULL_END
