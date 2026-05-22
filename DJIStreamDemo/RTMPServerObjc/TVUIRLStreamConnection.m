//
//  TVUIRLStreamConnection.m
//  DJIStreamDemo
//

#import "TVUIRLStreamConnection.h"
#import "TVUIRLDJILog.h"
#import "TVUIRLStreamingServer.h"
#import "TVUIRLStreamingServer+Internal.h"
#import "TVUIRLMediaPipeline.h"
#import "TVUIRLMediaPacket.h"
#import "TVUIRLProtocolMessage.h"
#import "TVUIRLAckMessage.h"
#import "TVUIRLMediaClock.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <sys/time.h>

static const uint8_t kRtmpVersion = 3;

/// Ring buffer 主缓冲容量。10Mbps × 6s ≈ 7.5MB，留 0.5MB 余量。
static const NSInteger kTVUIRLRingCapacity    = 8 * 1024 * 1024;
/// Overflow B 首次分配容量；按需 realloc 至 kTVUIRLOverflowMaxCap 上限。
static const NSInteger kTVUIRLOverflowInitCap = 256 * 1024;
/// Overflow B 上限；超过后写入返回 NO，调用方应触发 stopInternal。
static const NSInteger kTVUIRLOverflowMaxCap  = 4 * 1024 * 1024;

/// 8MB malloc 环形缓冲：替代原 inputBuffer (NSMutableData)，消除 appendData/compact/dataWithBytes 三处热点。
/// 几何不变量见 Plans/10_RingBuffer替换inputBuffer方案.md。
typedef struct {
    uint8_t   *base;     ///< malloc 起点
    NSInteger  capacity; ///< 容量上限（字节）
    NSInteger  readIdx;  ///< 物理读位置 ∈ [0, capacity)
    NSInteger  writeIdx; ///< 物理写位置 ∈ [0, capacity)
    NSInteger  used;     ///< 当前未消费字节数 ∈ [0, capacity]
    NSInteger  validEnd; ///< 有效数据末尾物理位置；路径 (a) 触底 wrap 时仍 == capacity，路径 (b) 强制 wrap 时 < capacity
} TVUIRLRingBuffer;

/// Overflow 旁路缓冲：ring 满或写入跨边界时暂存，FIFO 严格保序，readIdx 推进后顺手 drain。
typedef struct {
    uint8_t   *buf;      ///< dynamic malloc，首次需要时分配
    NSInteger  capacity; ///< 当前 malloc 容量；初始 256 KB，上限 4 MB
    NSInteger  len;      ///< 当前有效字节
} TVUIRLOverflowB;

typedef NS_ENUM(NSInteger, TVUIRLConnectionHsState) {
    TVUIRLConnectionHsUninitialized,
    TVUIRLConnectionHsVersionSent,
    TVUIRLConnectionHsAckSent,
    TVUIRLConnectionHsHandshakeDone,
};

typedef NS_ENUM(NSInteger, TVUIRLChunkParserState) {
    TVUIRLChunkBasicHeaderFirstByte,
    TVUIRLChunkMessageHeaderType0,
    TVUIRLChunkMessageHeaderType1,
    TVUIRLChunkMessageHeaderType2,
    TVUIRLChunkExtendedTimestamp,
    TVUIRLChunkData,
};

@interface TVUIRLStreamConnection () {
    /// 保护下面的解码出口锚状态字段。VT 异步回调线程与 RTMP socket 线程会并发触发 remap*。
    os_unfair_lock _anchorLock;
    /// 替代 inputBuffer (NSMutableData)：8MB malloc ring + overflow B 旁路。
    /// 写入侧 chunk 不切分（单次 NSData 整段进 ring 或整段进 B），
    /// 读取侧 ringReadAdvance / ringConsume 内部处理跨 wrap 拼接。
    TVUIRLRingBuffer _ring;
    TVUIRLOverflowB  _overflow;
    /// RTMP basic header chunkStreamId 只有 6 位（值域 2–63），直接用 C 数组替代 NSDictionary，
    /// 消除 NSNumber boxing + hash 查找开销（~3900 次/秒热点路径）。
    TVUIRLMediaPipeline *_pipelineSlots[64];
}
@property (nonatomic, weak, readwrite) TVUIRLStreamingServer *server;
@property (nonatomic, strong) id<TVUIRLTransportConnection> transport;
@property (nonatomic, assign) TVUIRLConnectionHsState hsState;
@property (nonatomic, assign) TVUIRLChunkParserState chunkState;
/// Phase 3 以后仅用于暂存当前 TVUIRLChunkData 帧体字节数（由 nextChunkDataSize 算得）。
@property (nonatomic, assign) NSInteger receiveSize;
@property (nonatomic, assign) uint64_t totalBytesReceived;
@property (nonatomic, assign) uint64_t totalBytesReceivedAcked;
@property (nonatomic, weak) TVUIRLMediaPipeline *currentPipeline;
@property (nonatomic, assign, readwrite) CFAbsoluteTime latestReceiveAbsTime;
@property (nonatomic, strong) TVUIRLMediaClock *mediaClock;
@property (nonatomic, assign) double basePresentationTimeStampMsValue;
@property (nonatomic, assign) BOOL hasBasePresentationTimeStamp;

/// 解码出口锚 —— basetime 在 video 首帧锚定，之后由 PLL **慢牵**抵消源端 vs 主机时钟差。
/// 单帧 correction 限幅 ±1ms，保证 newPts step 仍 ≥ 32ms 不触发下游单调性问题。
/// audio 共享 basetime 只读不写，basetime 未就绪时 audio 整帧丢弃。
/// stopWithReason: 时整体归零，下次 publish 重新锚。
@property (nonatomic, assign) BOOL anchorBasetimeReady;
@property (nonatomic, assign) CMTime anchorBasetime;
@property (nonatomic, assign) BOOL videoFirstPtsReady;
@property (nonatomic, assign) CMTime videoFirstPts;
@property (nonatomic, assign) BOOL audioFirstPtsReady;
@property (nonatomic, assign) CMTime audioFirstPts;
@property (nonatomic, assign) CMTime firstVideoNewPts;
/// 仅用于打印相邻两帧 newPts 增量（step=）。每帧覆盖。
@property (nonatomic, assign) CMTime lastVideoNewPtsForLog;
/// 防御性单调 clamp：极端 video burst 下 PLL 多次连续下拉 basetime 可能让 audio newPts 不增；
/// 保证 audio newPts 严格单调，绕过 TVUAudioEncoderManager 的 last_audio_pts 守卫。
@property (nonatomic, assign) CMTime lastAudioNewPts;
/// 严格时间戳校验用：输出域首帧 newPts（理论值基准）；上一帧 newPts（step 计算）。
@property (nonatomic, assign) CMTime audioFirstNewPts;
@property (nonatomic, assign) BOOL audioFirstNewPtsReady;
@property (nonatomic, assign) CMTime lastAudioNewPtsForStep;
/// PLL 状态：EMA 平滑后的 drift（ms），diagnostic 累计 correction（ms）
@property (nonatomic, assign) double filteredDriftMs;
@property (nonatomic, assign) double totalPllCorrectionMs;
/// DEBUG 节流计数器：每帧自增, 取模触发 drift 日志。Release 下也自增但开销可忽略。
@property (nonatomic, assign) uint64_t videoRemapDebugCounter;
@property (nonatomic, assign) uint64_t audioRemapDebugCounter;
@property (nonatomic, assign) uint64_t audioDroppedDebugCounter;
/// transport 是否已经切到批量化接收。握手期 + RTMP 控制流期（connect/createStream/publish
/// 等小消息往返）必须保持默认 min=1，否则小消息凑不齐 batch 会死锁。等真正进入连续媒体
/// 流阶段（第一个有实际负载的 video 帧到达）才切到 min=8KB。仅切换一次。
@property (nonatomic, assign) BOOL receiveBatchModeEnabled;
@end

@implementation TVUIRLStreamConnection

- (instancetype)initWithServer:(TVUIRLStreamingServer *)server transport:(id<TVUIRLTransportConnection>)transport {
    if (self = [super init]) {
        _server = server;
        _transport = transport;
        _hsState = TVUIRLConnectionHsUninitialized;
        _chunkState = TVUIRLChunkBasicHeaderFirstByte;
        _ring.base = (uint8_t *)malloc((size_t)kTVUIRLRingCapacity);
        _ring.capacity = kTVUIRLRingCapacity;
        _ring.validEnd = kTVUIRLRingCapacity;
        // _ring.readIdx / writeIdx / used 与 _overflow 已 zero-init。
        _receiveSize = 1 + 1536;
        _streamKey = @"";
        _latency = 2000;
        _cameraId = [NSUUID UUID];
        _chunkSizeFromClient = 128;
        _chunkSizeToClient = 128;
        _windowAcknowledgementSize = 2500000;
        _latestReceiveAbsTime = CFAbsoluteTimeGetCurrent();
        _mediaClock = [[TVUIRLMediaClock alloc] initWithTargetLatency:2.0];
        _lifecycle = TVUIRLConnectionLifecycleIdle;
        _anchorLock = OS_UNFAIR_LOCK_INIT;
        _anchorBasetime = kCMTimeInvalid;
        _videoFirstPts = kCMTimeInvalid;
        _audioFirstPts = kCMTimeInvalid;
        _firstVideoNewPts = kCMTimeInvalid;
        _lastVideoNewPtsForLog = kCMTimeInvalid;
        _lastAudioNewPts = kCMTimeInvalid;
        _audioFirstNewPts = kCMTimeInvalid;
        _lastAudioNewPtsForStep = kCMTimeInvalid;
        _filteredDriftMs = 0.0;
        _totalPllCorrectionMs = 0.0;
    }
    return self;
}

- (void)dealloc {
    TVUIRLDJILog(@"[leak-check] TVUIRLStreamConnection dealloc (key=%@)", _streamKey);
    if (_ring.base)    { free(_ring.base);    _ring.base = NULL; }
    if (_overflow.buf) { free(_overflow.buf); _overflow.buf = NULL; }
}

- (void)start {
    self.lifecycle = TVUIRLConnectionLifecycleConnecting;
    __weak typeof(self) weakSelf = self;
    [self.transport startWithQueue:self.server.serverQueue
                    receiveHandler:^(NSData *data) {
        [weakSelf processReceivedData:data];
    }
                    failureHandler:^(NSError * _Nullable error) {
        NSString *reason = error ? error.localizedDescription : @"Disconnected";
        [weakSelf stopInternal:reason];
    }];
}

- (void)stopWithReason:(NSString *)reason {
    TVUIRLDJILog(@"rtmp-server: client stopping: %@", reason);
    for (int i = 0; i < 64; i++) {
        [_pipelineSlots[i] stop];
        _pipelineSlots[i] = nil;
    }
    [self.transport cancel];
    self.lifecycle = TVUIRLConnectionLifecycleIdle;
    [self resetDecodedPtsAnchor];
}

/// 归零解码出口锚状态，下次 publish 时按新 session 重新锚定。
- (void)resetDecodedPtsAnchor {
    os_unfair_lock_lock(&_anchorLock);
    self.anchorBasetimeReady = NO;
    self.anchorBasetime = kCMTimeInvalid;
    self.videoFirstPtsReady = NO;
    self.videoFirstPts = kCMTimeInvalid;
    self.audioFirstPtsReady = NO;
    self.audioFirstPts = kCMTimeInvalid;
    self.firstVideoNewPts = kCMTimeInvalid;
    self.lastVideoNewPtsForLog = kCMTimeInvalid;
    self.lastAudioNewPts = kCMTimeInvalid;
    self.audioFirstNewPts = kCMTimeInvalid;
    self.audioFirstNewPtsReady = NO;
    self.lastAudioNewPtsForStep = kCMTimeInvalid;
    self.filteredDriftMs = 0.0;
    self.totalPllCorrectionMs = 0.0;
    self.videoRemapDebugCounter = 0;
    self.audioRemapDebugCounter = 0;
    self.audioDroppedDebugCounter = 0;
    os_unfair_lock_unlock(&_anchorLock);
}

- (void)stopInternal:(NSString *)reason {
    if (self.lifecycle == TVUIRLConnectionLifecycleIdle) return;
    [self.server connectionDidDisconnect:self reason:reason];
}

#pragma mark - Chunk parsing (Phase 3：状态机内联，单一 while + switch，消除所有 handler/request 的 ObjC dispatch)

- (void)processReceivedData:(NSData *)data {
    self.totalBytesReceived += data.length;
    [self.server.bandwidthMeter addBytesTransferred:(NSInteger)data.length];
    self.latestReceiveAbsTime = CFAbsoluteTimeGetCurrent();

    // 1) 先尝试 drain B（前一轮可能因 ring 满而阻塞的字节）；2) 把本次 NSData 写进 ring 或 B。
    [self ringDrainOverflow];
    if (![self ringWriteBytes:data.bytes length:(NSInteger)data.length]) {
        [self stopInternal:@"Ring overflow"];
        return;
    }

    // 握手冷路径：每连接仅 2 次，读到 stack buf 拷贝处理。
    while (self.hsState != TVUIRLConnectionHsHandshakeDone) {
        NSInteger hsSize;
        switch (self.hsState) {
            case TVUIRLConnectionHsUninitialized: hsSize = 1 + 1536; break;
            case TVUIRLConnectionHsAckSent:       hsSize = 1536;     break;
            default: goto done; // HsVersionSent 是 handleHandshakeC0C1: 内部的瞬态，外部不可见
        }
        uint8_t hsBuf[1537];
        if (![self ringReadAdvance:hsBuf length:hsSize]) goto done;
        if (self.hsState == TVUIRLConnectionHsUninitialized) {
            // dataWithBytes:length: 复制：handshake 是 2x/连接的冷路径，避免 hsBuf 出栈后悬指针。
            NSData *d = [NSData dataWithBytes:hsBuf length:(NSUInteger)hsSize];
            [self handleHandshakeC0C1:d];
        } else {
            [self handleHandshakeC2];
        }
    }

    // RTMP chunk 解析热路径：状态机内联，从 ring 读取并由 ringConsume 把 chunk 体直传 pipeline（0 拷贝），
    // 跨 wrap 时 ringReadAdvance / ringConsume 内部自动两段拼接，对状态机透明。
    while (_ring.used > 0) {
        switch (_chunkState) {

            case TVUIRLChunkBasicHeaderFirstByte: {
                uint8_t firstByte;
                if (![self ringReadAdvance:&firstByte length:1]) goto done;
                uint8_t format        = firstByte >> 6;
                uint8_t chunkStreamId = firstByte & 0x3F;
                if (chunkStreamId == 0) { [self stopInternal:@"Two bytes basic header is not implemented"]; goto done; }
                if (chunkStreamId == 1) { [self stopInternal:@"Three bytes basic header is not implemented"]; goto done; }
                TVUIRLMediaPipeline *p = _pipelineSlots[chunkStreamId];
                if (!p) {
                    p = [[TVUIRLMediaPipeline alloc] initWithConnection:self chunkStreamId:chunkStreamId];
                    _pipelineSlots[chunkStreamId] = p;
                }
                self.currentPipeline = p;
                switch (format) {
                    case 0: _chunkState = TVUIRLChunkMessageHeaderType0; break;
                    case 1: _chunkState = TVUIRLChunkMessageHeaderType1; break;
                    case 2: _chunkState = TVUIRLChunkMessageHeaderType2; break;
                    case 3:
                        // type3：无 message header，直接复用上次 pipeline 的 messageLength
                        if (self.currentPipeline.extendedTimestampPresentInType3) {
                            _chunkState = TVUIRLChunkExtendedTimestamp;
                        } else {
                            NSInteger size = [self.currentPipeline nextChunkDataSize];
                            if (size <= 0) { [self stopInternal:@"Unexpected data"]; goto done; }
                            _chunkState = TVUIRLChunkData;
                            _receiveSize = size;
                        }
                        break;
                    default: [self stopInternal:@"Invalid chunk format"]; goto done;
                }
                break;
            }

            case TVUIRLChunkMessageHeaderType0: {
                uint8_t b[11];
                if (![self ringReadAdvance:b length:11]) goto done;
                self.currentPipeline.isAbsoluteTimestamp = YES;
                self.currentPipeline.messageTimestamp    = (b[0] << 16) | (b[1] << 8) | b[2];
                self.currentPipeline.messageLength       = (NSInteger)((b[3] << 16) | (b[4] << 8) | b[5]);
                self.currentPipeline.messageTypeId       = b[6];
                self.currentPipeline.messageStreamId     = (uint32_t)b[7] | ((uint32_t)b[8] << 8) | ((uint32_t)b[9] << 16) | ((uint32_t)b[10] << 24);
                if (self.currentPipeline.messageTimestamp == 0xFFFFFF) {
                    self.currentPipeline.extendedTimestampPresentInType3 = YES;
                    _chunkState = TVUIRLChunkExtendedTimestamp;
                } else {
                    self.currentPipeline.extendedTimestampPresentInType3 = NO;
                    NSInteger size = [self.currentPipeline nextChunkDataSize];
                    if (size <= 0) { [self stopInternal:@"Unexpected data"]; goto done; }
                    _chunkState = TVUIRLChunkData;
                    _receiveSize = size;
                }
                break;
            }

            case TVUIRLChunkMessageHeaderType1: {
                uint8_t b[7];
                if (![self ringReadAdvance:b length:7]) goto done;
                self.currentPipeline.isAbsoluteTimestamp = NO;
                self.currentPipeline.messageTimestamp    = (b[0] << 16) | (b[1] << 8) | b[2];
                self.currentPipeline.messageLength       = (NSInteger)((b[3] << 16) | (b[4] << 8) | b[5]);
                self.currentPipeline.messageTypeId       = b[6];
                if (self.currentPipeline.messageTimestamp == 0xFFFFFF) {
                    self.currentPipeline.extendedTimestampPresentInType3 = YES;
                    _chunkState = TVUIRLChunkExtendedTimestamp;
                } else {
                    self.currentPipeline.extendedTimestampPresentInType3 = NO;
                    NSInteger size = [self.currentPipeline nextChunkDataSize];
                    if (size <= 0) { [self stopInternal:@"Unexpected data"]; goto done; }
                    _chunkState = TVUIRLChunkData;
                    _receiveSize = size;
                }
                break;
            }

            case TVUIRLChunkMessageHeaderType2: {
                uint8_t b[3];
                if (![self ringReadAdvance:b length:3]) goto done;
                self.currentPipeline.isAbsoluteTimestamp = NO;
                self.currentPipeline.messageTimestamp    = (b[0] << 16) | (b[1] << 8) | b[2];
                if (self.currentPipeline.messageTimestamp == 0xFFFFFF) {
                    self.currentPipeline.extendedTimestampPresentInType3 = YES;
                    _chunkState = TVUIRLChunkExtendedTimestamp;
                } else {
                    self.currentPipeline.extendedTimestampPresentInType3 = NO;
                    NSInteger size = [self.currentPipeline nextChunkDataSize];
                    if (size <= 0) { [self stopInternal:@"Unexpected data"]; goto done; }
                    _chunkState = TVUIRLChunkData;
                    _receiveSize = size;
                }
                break;
            }

            case TVUIRLChunkExtendedTimestamp: {
                uint8_t b[4];
                if (![self ringReadAdvance:b length:4]) goto done;
                self.currentPipeline.messageTimestamp = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
                NSInteger size = [self.currentPipeline nextChunkDataSize];
                if (size <= 0) { [self stopInternal:@"Unexpected data"]; goto done; }
                _chunkState = TVUIRLChunkData;
                _receiveSize = size;
                break;
            }

            case TVUIRLChunkData: {
                NSInteger needed = _receiveSize;
                if (_ring.used < needed) goto done;
                [self maybeEnableReceiveBatchMode];
                [self ringConsume:needed intoPipeline:self.currentPipeline];
                _chunkState = TVUIRLChunkBasicHeaderFirstByte;
                break;
            }
        }
    }

done:
    if (self.totalBytesReceived - self.totalBytesReceivedAcked > (uint64_t)self.windowAcknowledgementSize) {
        [self sendAck];
        self.totalBytesReceivedAcked = self.totalBytesReceived;
    }
}

#pragma mark - Ring buffer

/// 写入 length 字节到 ring。永远不切分单次写入：
///   路径 (a) 尾部连续：直接 memcpy；触底时 writeIdx 回 0（validEnd 不变）
///   路径 (b) 强制 wrap：tail 不够但 readIdx >= length，标记 validEnd 后写到 base+0
///   路径 (c) overflow B：ring 满或 (b) 不满足时入旁路
/// I5：B 非空时新数据先入 B，保 FIFO。
/// @return YES 成功；NO 表示 overflow B 已超 max 上限，调用方应触发 stopInternal。
- (BOOL)ringWriteBytes:(const void *)bytes length:(NSInteger)length {
    if (length <= 0) return YES;

    // I5: B 非空时新数据排在 B 之后。
    if (_overflow.len > 0) {
        if (![self overflowAppend:bytes length:length]) return NO;
        [self ringDrainOverflow];
        return YES;
    }

    // 空 ring：重置到 canonical 状态，单次写入拥有完整 capacity 连续空间。
    if (_ring.used == 0) {
        _ring.writeIdx = 0;
        _ring.readIdx = 0;
        _ring.validEnd = _ring.capacity;
    }

    NSInteger remaining = _ring.capacity - _ring.used;
    if (length > remaining) {
        return [self overflowAppend:bytes length:length];
    }

    NSInteger contig;
    if (_ring.used == 0) {
        contig = _ring.capacity;
    } else if (_ring.writeIdx >= _ring.readIdx) {
        // 未 wrap：尾部到 capacity
        contig = _ring.capacity - _ring.writeIdx;
    } else {
        // 已 wrap：写到 readIdx 之前
        contig = _ring.readIdx - _ring.writeIdx;
    }

    if (length <= contig) {
        memcpy(_ring.base + _ring.writeIdx, bytes, (size_t)length);
        _ring.writeIdx += length;
        if (_ring.writeIdx == _ring.capacity) _ring.writeIdx = 0;
        _ring.used += length;
        return YES;
    }

    // 路径 (b)：仅未 wrap 状态可执行（已 wrap 时 contig 是确定上限，length>contig 必须走 overflow）。
    if (_ring.writeIdx > _ring.readIdx && _ring.readIdx >= length) {
        _ring.validEnd = _ring.writeIdx;
        memcpy(_ring.base, bytes, (size_t)length);
        _ring.writeIdx = length;
        _ring.used += length;
        return YES;
    }

    // 路径 (c)
    return [self overflowAppend:bytes length:length];
}

/// 读 length 字节到 dest 并推进 readIdx。跨 wrap 时内部两段 memcpy 拼接。
/// header 解析专用（dest 是状态机栈上 1/3/4/7/11 字节 buf）。
/// @return YES 成功；NO 表示数据不足（dest 未修改，readIdx 未推进）。
- (BOOL)ringReadAdvance:(uint8_t *)dest length:(NSInteger)length {
    if (length <= 0) return YES;
    if (_ring.used < length) return NO;

    // 是否已 wrap：writeIdx < readIdx 或 (writeIdx == readIdx 且 used == capacity, 即满)
    BOOL isWrapped = (_ring.writeIdx < _ring.readIdx) ||
                     (_ring.writeIdx == _ring.readIdx && _ring.used == _ring.capacity);
    NSInteger tailLen = isWrapped
                       ? (_ring.validEnd - _ring.readIdx)
                       : (_ring.writeIdx - _ring.readIdx);

    if (length <= tailLen) {
        memcpy(dest, _ring.base + _ring.readIdx, (size_t)length);
        _ring.readIdx += length;
        if (isWrapped && _ring.readIdx >= _ring.validEnd) {
            _ring.readIdx = 0;
            _ring.validEnd = _ring.capacity;
        }
    } else {
        // 跨 wrap：tail 段 + head 段
        memcpy(dest, _ring.base + _ring.readIdx, (size_t)tailLen);
        NSInteger headTake = length - tailLen;
        memcpy(dest + tailLen, _ring.base, (size_t)headTake);
        _ring.readIdx = headTake;
        _ring.validEnd = _ring.capacity;
    }
    _ring.used -= length;
    if (_overflow.len > 0) [self ringDrainOverflow];
    return YES;
}

/// 把 length 字节交给 pipeline raw 入口（appendChunkRawBytes:length:）并推进 readIdx。
/// 未跨 wrap：单次指针直传（0 拷贝命中 plan 设计目标）；
/// 跨 wrap：拆成两段分别 append，messageBody 拼接结果与一段等价。
/// @return YES 成功；NO 表示数据不足。
- (BOOL)ringConsume:(NSInteger)length intoPipeline:(TVUIRLMediaPipeline *)pipeline {
    if (length <= 0) return YES;
    if (_ring.used < length) return NO;

    BOOL isWrapped = (_ring.writeIdx < _ring.readIdx) ||
                     (_ring.writeIdx == _ring.readIdx && _ring.used == _ring.capacity);
    NSInteger tailLen = isWrapped
                       ? (_ring.validEnd - _ring.readIdx)
                       : (_ring.writeIdx - _ring.readIdx);

    if (length <= tailLen) {
        [pipeline appendChunkRawBytes:_ring.base + _ring.readIdx length:length];
        _ring.readIdx += length;
        if (isWrapped && _ring.readIdx >= _ring.validEnd) {
            _ring.readIdx = 0;
            _ring.validEnd = _ring.capacity;
        }
    } else {
        [pipeline appendChunkRawBytes:_ring.base + _ring.readIdx length:tailLen];
        NSInteger headTake = length - tailLen;
        [pipeline appendChunkRawBytes:_ring.base length:headTake];
        _ring.readIdx = headTake;
        _ring.validEnd = _ring.capacity;
    }
    _ring.used -= length;
    if (_overflow.len > 0) [self ringDrainOverflow];
    return YES;
}

/// 尝试把 overflow B 中的数据搬回 ring，按 FIFO 顺序整体推进。
/// 触发时机：processReceivedData 入口；ringReadAdvance / ringConsume 释放 ring 空间后。
- (void)ringDrainOverflow {
    while (_overflow.len > 0) {
        NSInteger remaining = _ring.capacity - _ring.used;
        if (remaining == 0) return;

        if (_ring.used == 0) {
            _ring.writeIdx = 0;
            _ring.readIdx = 0;
            _ring.validEnd = _ring.capacity;
        }

        NSInteger contig;
        if (_ring.used == 0) {
            contig = _ring.capacity;
        } else if (_ring.writeIdx >= _ring.readIdx) {
            contig = _ring.capacity - _ring.writeIdx;
        } else {
            contig = _ring.readIdx - _ring.writeIdx;
        }

        if (contig == 0) {
            // writeIdx 撞 capacity 或 readIdx；尝试 wrap writeIdx 释放头部空间。
            if (_ring.writeIdx > _ring.readIdx && _ring.readIdx > 0) {
                _ring.validEnd = _ring.writeIdx;
                _ring.writeIdx = 0;
                continue;
            }
            return;
        }

        NSInteger n = MIN(_overflow.len, MIN(contig, remaining));
        memcpy(_ring.base + _ring.writeIdx, _overflow.buf, (size_t)n);
        _ring.writeIdx += n;
        if (_ring.writeIdx == _ring.capacity) _ring.writeIdx = 0;
        _ring.used += n;
        _overflow.len -= n;
        if (_overflow.len > 0) {
            memmove(_overflow.buf, _overflow.buf + n, (size_t)_overflow.len);
        }
    }
}

/// 追加到 overflow B；按需 realloc，超出上限 kTVUIRLOverflowMaxCap 返回 NO。
- (BOOL)overflowAppend:(const void *)bytes length:(NSInteger)length {
    if (length <= 0) return YES;
    NSInteger needCap = _overflow.len + length;
    if (needCap > kTVUIRLOverflowMaxCap) {
        return NO;
    }
    if (needCap > _overflow.capacity) {
        NSInteger newCap = (_overflow.capacity > 0) ? _overflow.capacity : kTVUIRLOverflowInitCap;
        while (newCap < needCap) newCap *= 2;
        if (newCap > kTVUIRLOverflowMaxCap) newCap = kTVUIRLOverflowMaxCap;
        uint8_t *newBuf = (uint8_t *)realloc(_overflow.buf, (size_t)newCap);
        if (!newBuf) return NO;
        _overflow.buf = newBuf;
        _overflow.capacity = newCap;
    }
    memcpy(_overflow.buf + _overflow.len, bytes, (size_t)length);
    _overflow.len += length;
    return YES;
}

#pragma mark - Handshake

- (void)handleHandshakeC0C1:(NSData *)data {
    if (data.length != 1 + 1536) {
        [self stopInternal:[NSString stringWithFormat:@"Wrong length %lu in uninitialized", (unsigned long)data.length]];
        return;
    }
    const uint8_t *bytes = data.bytes;
    if (bytes[0] != kRtmpVersion) {
        [self stopInternal:[NSString stringWithFormat:@"Only RTMP version 3 supported, got %u", bytes[0]]];
        return;
    }
    // S0
    uint8_t s0 = kRtmpVersion;
    [self sendBytes:[NSData dataWithBytes:&s0 length:1]];
    // S1: 8 zeros + 1528 random
    NSMutableData *s1 = [NSMutableData dataWithLength:8];
    NSMutableData *random = [NSMutableData dataWithLength:1528];
    arc4random_buf(random.mutableBytes, 1528);
    [s1 appendData:random];
    [self sendBytes:s1];
    self.hsState = TVUIRLConnectionHsVersionSent;
    // S2: C1[0..3] + 0(4) + C1[8..]
    NSMutableData *s2 = [NSMutableData data];
    [s2 appendBytes:bytes + 1 length:4];
    uint8_t zeros[4] = {0};
    [s2 appendBytes:zeros length:4];
    [s2 appendBytes:bytes + 9 length:1528];
    [self sendBytes:s2];
    self.hsState = TVUIRLConnectionHsAckSent;
}

- (void)handleHandshakeC2 {
    self.hsState = TVUIRLConnectionHsHandshakeDone;
    _chunkState = TVUIRLChunkBasicHeaderFirstByte;
}

/// 第一次见到真实负载的 video chunk（排除 AVC/HEVC 配置帧 ~50B）就切到批量化接收。
/// 走到这里说明 RTMP 控制流（SetChunkSize / connect / releaseStream / FCPublish /
/// createStream / publish / onStatus）已经全部完成、推流已经稳定，后续都是连续大流量。
/// 此时把 nw_connection_receive 的 min_byte_count 从 1 抬到 8KB，回调频率 ~5x 下降。
- (void)maybeEnableReceiveBatchMode {
    if (self.receiveBatchModeEnabled) return;
    if (self.currentPipeline.messageTypeId != TVUIRLMessageTypeVideo) return;
    if (self.currentPipeline.messageLength <= 1024) return;  // 跳过 AVC/HEVC config
    self.receiveBatchModeEnabled = YES;
    if ([self.transport respondsToSelector:@selector(setReceiveBatchMinBytes:)]) {
        [self.transport setReceiveBatchMinBytes:8192];
        TVUIRLDJILog(@"[nw_recv] entering batch mode (min_byte=8192) after first real video frame");
    }
}

#pragma mark - Send

- (void)sendBytes:(NSData *)data {
    if (data.length == 0) return;
    [self.transport writeData:data];
}

- (void)sendMessagePacket:(TVUIRLMediaPacket *)packet {
    NSArray<NSData *> *chunks = [packet splitWithMaximumSize:self.chunkSizeToClient];
    for (NSData *c in chunks) {
        [self sendBytes:c];
    }
}

- (void)sendAck {
    TVUIRLAckMessage *msg = [[TVUIRLAckMessage alloc] init];
    msg.sequence = (uint32_t)(self.totalBytesReceived & 0xFFFFFFFFu);
    TVUIRLMediaPacket *packet = [[TVUIRLMediaPacket alloc] initWithType:TVUIRLPacketTypeZero
                                                          chunkStreamId:TVUIRLChunkStreamIdControl
                                                                message:msg];
    [self sendMessagePacket:packet];
}

#pragma mark - Pipeline callbacks

- (void)pipelineDidProduceVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.server forwardVideoSampleBuffer:sampleBuffer];
}

- (void)pipelineDidProduceVideoImageBuffer:(CVImageBufferRef)imageBuffer {
    [self.server forwardVideoImageBuffer:imageBuffer];
}

- (void)pipelineDidProduceAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [self.server forwardAudioSampleBuffer:sampleBuffer];
}

- (void)pipelineDidObserveAudioPts:(double)pts {
    [self.mediaClock setLatestAudioPresentationTimeStamp:pts];
    [self updateTargetLatencies];
}

- (void)pipelineDidObserveVideoPts:(double)pts {
    [self.mediaClock setLatestVideoPresentationTimeStamp:pts];
    [self updateTargetLatencies];
}

- (void)updateTargetLatencies {
    TVUIRLMediaClockDecision decision = [self.mediaClock update];
    if (decision.hasUpdate) {
        [self.server forwardTargetVideoLatency:decision.videoTargetLatency
                                  audioLatency:decision.audioTargetLatency];
    }
}

- (double)basePresentationTimeStampMs {
    if (!self.hasBasePresentationTimeStamp) {
        self.basePresentationTimeStampMsValue = 1000.0 * CACurrentMediaTime();
        self.hasBasePresentationTimeStamp = YES;
    }
    return self.basePresentationTimeStampMsValue;
}

#pragma mark - TVUIRLDecodedPtsAnchor

// 解码出口 PTS 重写：把"流内 PTS"折回到 host time 域。公式：newPts = basetime + (pts - firstPts_self)。
//
// basetime 在 video 首帧锚定，之后用 **PLL 慢牵** 抵消源端 vs 主机时钟差（ppm 漂移）。
//   - EMA 平滑 drift，比例反馈，单帧 correction 限幅 ±1ms
//   - step = 33ms − correction ∈ [32, 34]ms，对下游编码器透明
//   - 可对抗最大 30000ppm 速率差，远超典型 1000ppm
//
//  ppm = parts per million，即百万分之一。30000 ppm 就是 3% 的速率差（30000 ÷ 1,000,000 = 0.03）。
//  常见的设备时钟误差在 ±50~100 ppm，通信协议通常要求设备间的时钟差不超过 ±1000 ppm（0.1%）。
// audio 共享 basetime（只读，不参与 PLL），未就绪时整帧丢弃。
// stopWithReason: 时整体归零（含 PLL 状态），下次 publish 重新锚。

- (CMTime)remapVideoDecodedPts:(CMTime)pts {
    if (!CMTIME_IS_VALID(pts)) return pts;
    // 锁外读 CACurrentMediaTime，缩短临界区
    CFTimeInterval nowSec = CACurrentMediaTime();

    // PLL 参数：见上方注释中的设计。微秒 timescale 让 correction 子毫秒精度也能落地。
    // 微秒,提高精度，确保 1ms 以下的修正不会因舍入误差失效。
    static const int32_t kBasetimeScale = 1000000;
    // 平滑系数。数值越小，对抖动越不敏感，但调整速度越慢, 时间常数 ~6.7s @ 30fps
    // 一次抖动被平均分摊在 6.7s 内消化
    static const double kEmaAlpha = 0.005;
    // 反馈增益。决定了发现偏差后，"追赶"的速度。correction = filtered * gain
    static const double kPllGain = 0.01;
    // 运维指标。通过它能算出两台设备的实际 PPM 差。限幅，保证 step ≥ 32ms
    static const double kMaxCorrectionMsPerFrame = 1.0;
    // 异常 drift 守卫：filtered drift > 5s 肯定不是 ppm(时钟) 漂移
    // 如果平滑后的误差超过 5 秒，说明不是正常的时钟漂移，而是发生了重大事故（如源端断流重连、时间戳跳变）
    //（可能源端 PTS 跳变 / VT session 异常 / 跨时钟域错位）→ 整体 reset 重锚
    static const double kInsaneDriftMs = 5000.0;

    os_unfair_lock_lock(&_anchorLock);
    if (!self.videoFirstPtsReady) {
        self.videoFirstPts = pts;
        self.videoFirstPtsReady = YES;
    }
    if (!self.anchorBasetimeReady) {
        // 首帧一次性锚定，用微秒 timescale，让后续 PLL sub-ms correction 不丢精度
        self.anchorBasetime = CMTimeMakeWithSeconds(nowSec, kBasetimeScale);
        self.anchorBasetimeReady = YES;
    }
    CMTime sourceDelta = CMTimeSubtract(pts, self.videoFirstPts);
    CMTime newPts = CMTimeAdd(self.anchorBasetime, sourceDelta);
    if (!CMTIME_IS_VALID(self.firstVideoNewPts)) {
        self.firstVideoNewPts = newPts;
    }

    // PLL 反馈：drift > 0 (newPts 在 now 未来) → 减小 basetime；反之加
    double newPtsSec = CMTimeGetSeconds(newPts);
    double driftMs = (newPtsSec - nowSec) * 1000.0;
    // 过滤掉网络抖动带来的瞬时误差，只捕捉长期的时钟频率偏差
    self.filteredDriftMs = self.filteredDriftMs * (1.0 - kEmaAlpha) + driftMs * kEmaAlpha;
    double correctionMs = 0.0;
    BOOL didInsaneReset = NO;
    if (fabs(self.filteredDriftMs) > kInsaneDriftMs) {
        // Panic 路径：归零锚，下一帧从头开始
        self.anchorBasetimeReady = NO;
        self.anchorBasetime = kCMTimeInvalid;
        self.videoFirstPtsReady = NO;
        self.videoFirstPts = kCMTimeInvalid;
        self.audioFirstPtsReady = NO;
        self.audioFirstPts = kCMTimeInvalid;
        self.firstVideoNewPts = kCMTimeInvalid;
        self.lastVideoNewPtsForLog = kCMTimeInvalid;
        self.lastAudioNewPts = kCMTimeInvalid;
        self.filteredDriftMs = 0.0;
        // totalPllCorrectionMs / counter 保留作为排查线索
        didInsaneReset = YES;
    } else {
        correctionMs = self.filteredDriftMs * kPllGain;
        if (correctionMs > kMaxCorrectionMsPerFrame) correctionMs = kMaxCorrectionMsPerFrame;
        if (correctionMs < -kMaxCorrectionMsPerFrame) correctionMs = -kMaxCorrectionMsPerFrame;
        int64_t correctionUs = (int64_t)llround(correctionMs * 1000.0);
        if (correctionUs != 0) {
            self.anchorBasetime = CMTimeSubtract(self.anchorBasetime,
                                                  CMTimeMake(correctionUs, kBasetimeScale));
            self.totalPllCorrectionMs += correctionMs;
        }
    }

    CMTime basetimeSnapshot = self.anchorBasetime;
    CMTime firstNewPtsSnapshot = self.firstVideoNewPts;
    CMTime lastForLogSnapshot = self.lastVideoNewPtsForLog;
    self.lastVideoNewPtsForLog = newPts;
    double filteredDriftSnapshot = self.filteredDriftMs;
    double totalCorrSnapshot = self.totalPllCorrectionMs;
    uint64_t counter = ++self.videoRemapDebugCounter;
    os_unfair_lock_unlock(&_anchorLock);

    // Panic 必报；常规日志节流到 ~1Hz @ 30fps（首帧 + 每 30 帧），减少日志噪声
    if (didInsaneReset) {
        TVUIRLDJILog(@"rtmp-server: video PLL PANIC reset (filt=%.0fms drift=%.0fms frame#%llu) — next frame re-anchors",
                     filteredDriftSnapshot, driftMs, counter);
    }
    BOOL shouldLog = (counter == 1) || (counter % 30 == 0);
    if (shouldLog) {
        // 日志：
        //   drift       = 原始 newPts - now，受瞬时抖动影响
        //   filtered    = EMA 平滑后的 drift，PLL 真正跟踪的量
        //   pllCorr     = 此帧 basetime 调整量（ms，正=往回调）
        //   totalCorr   = 累计 correction（ms），稳态后增长率应反映源-主机 ppm 差
        //   step        = 相邻 newPts 增量（PLL 工作后理论 ∈ [32, 34]ms）
        //   cumDiff     = newPts 与"严格 30fps 累加"理想差，捕捉源端帧率偏移
        //   pts-sys     = drift 的 epoch ms 整数版，方便和 AVFormatHttp offset 横向对照
        static const double kNominalFrameDurationMs = 1000.0 / 30.0; // 33.333...
        double newPtsSecAfter = CMTimeGetSeconds(newPts);
        double basetimeSec = CMTimeGetSeconds(basetimeSnapshot);
        double firstSec = CMTimeGetSeconds(firstNewPtsSnapshot);
        double theoreticalSec = firstSec + (double)(counter - 1) * kNominalFrameDurationMs / 1000.0;
        double cumDiffMs = (newPtsSecAfter - theoreticalSec) * 1000.0;
        double stepMs = CMTIME_IS_VALID(lastForLogSnapshot)
                      ? (newPtsSecAfter - CMTimeGetSeconds(lastForLogSnapshot)) * 1000.0
                      : 0.0;
        struct timeval tv;
        gettimeofday(&tv, NULL);
        int64_t sysEpochMs = (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
        int64_t ptsSysDiffMs = (int64_t)llround((newPtsSecAfter - nowSec) * 1000.0);
        int64_t newPtsEpochMs = sysEpochMs + ptsSysDiffMs;
        TVUIRLDJILog(@"rtmp-server: video drift=%.2fms filt=%.2fms pllCorr=%.3fms totalCorr=%.1fms newPts=%.3fs now=%.3fs base=%.3fs frame#%llu step=%.2fms cumDiff=%.2fms pts-sys=%lldms (newPtsEpoch=%lld sysEpoch=%lld)",
                     driftMs, filteredDriftSnapshot, correctionMs, totalCorrSnapshot,
                     newPtsSecAfter, nowSec, basetimeSec, counter, stepMs, cumDiffMs,
                     ptsSysDiffMs, newPtsEpochMs, sysEpochMs);
    }
    return newPts;
}

- (CMTime)remapAudioDecodedPts:(CMTime)pts {
    if (!CMTIME_IS_VALID(pts)) return pts;
    CFTimeInterval nowSec = CACurrentMediaTime();

    os_unfair_lock_lock(&_anchorLock);
    // 视频 basetime 未就绪 —— 整帧丢弃。返回 kCMTimeInvalid 由 audio decoder 侧识别并跳过。
    if (!self.anchorBasetimeReady) {
        uint64_t dropped = ++self.audioDroppedDebugCounter;
        os_unfair_lock_unlock(&_anchorLock);
        if (dropped == 1 || (dropped % 10) == 0) {
            TVUIRLDJILog(@"rtmp-server: audio dropped pre-video-base (count=%llu)", dropped);
        }
        return kCMTimeInvalid;
    }
    if (!self.audioFirstPtsReady) {
        self.audioFirstPts = pts;
        self.audioFirstPtsReady = YES;
    }
    CMTime sourceDelta = CMTimeSubtract(pts, self.audioFirstPts);
    CMTime newPts = CMTimeAdd(self.anchorBasetime, sourceDelta);
    // 防御性单调 clamp：极端 video burst 下 PLL 连续下拉 basetime 可能让 audio newPts ≤ 前帧
    BOOL clamped = NO;
    if (CMTIME_IS_VALID(self.lastAudioNewPts) &&
        CMTimeCompare(newPts, self.lastAudioNewPts) <= 0) {
        newPts = CMTimeAdd(self.lastAudioNewPts, CMTimeMake(1, pts.timescale));
        clamped = YES;
    }
    self.lastAudioNewPts = newPts;
    // 严格时间戳校验：记录首帧锚点 & 上帧 pts
    if (!self.audioFirstNewPtsReady) {
        self.audioFirstNewPts = newPts;
        self.audioFirstNewPtsReady = YES;
    }
    CMTime firstNewPtsSnapshot = self.audioFirstNewPts;
    CMTime prevPtsSnapshot = self.lastAudioNewPtsForStep;
    self.lastAudioNewPtsForStep = newPts;
    uint64_t counter = ++self.audioRemapDebugCounter;
    os_unfair_lock_unlock(&_anchorLock);

    // 每帧打印严格时间戳校验
    // step   = 相邻两帧 newPts 差值，应 ≈ 21.333ms；偏大说明真空，≤0 说明回退
    // theo   = 以首帧为基准、按 48kHz/1024 严格累加的理论值
    // diff   = 实际 - 理论，稳态应接近 0；持续漂移说明 DJI 音频时钟偏差
    // pts-now = newPts 与系统时钟的差（负值=PTS 落后系统时钟）
    {
        static const double kNominalAudioFrameSec = 1024.0 / 48000.0; // 21.333...ms
        double newPtsSec   = CMTimeGetSeconds(newPts);
        double theoPtsSec  = CMTimeGetSeconds(firstNewPtsSnapshot) + (double)(counter - 1) * kNominalAudioFrameSec;
        double diffMs      = (newPtsSec - theoPtsSec) * 1000.0;
        double stepMs      = CMTIME_IS_VALID(prevPtsSnapshot)
                           ? (newPtsSec - CMTimeGetSeconds(prevPtsSnapshot)) * 1000.0
                           : 0.0;
        BOOL isGap  = (counter > 1) && (stepMs > 32.0);
        BOOL isBack = (counter > 1) && (stepMs <= 0.0);
        BOOL shouldLog = (counter == 1) || (counter % 50 == 0) || isGap || isBack || clamped;
        if (shouldLog) {
            TVUIRLDJILog(@"[DJI ATS] #%05llu  pts=%.3fs  step=%+.2fms  theo=%.3fs  diff=%+.2fms  pts-now=%+.2fms%@%@%@",
                         (unsigned long long)counter,
                         newPtsSec, stepMs, theoPtsSec, diffMs,
                         (newPtsSec - nowSec) * 1000.0,
                         clamped ? @"  ⚠️CLAMP" : @"",
                         isGap   ? @"  ⚠️GAP"   : @"",
                         isBack  ? @"  ⚠️BACK"  : @"");
        }
    }
    return newPts;
}

@end
