# RTMPServerObjc 移植计划

**源项目：** Moblin (eerimoq/moblin) - MIT License
**目标项目：** TVUIRLSDK iOS
**语言：** Objective-C
**渲染路径：** 不需要 Metal，只保留 CMSampleBuffer 回调
**命名策略：** 使用意思相近但不同的类名，避免直接复制

---

## 零、命名对照表（关键类）

| Moblin Swift | Moblin 含义 | TVUIRL ObjC | 命名思路 |
|---|---|---|---|
| `RtmpServer` | RTMP 服务器 | `TVUIRLStreamingServer` | streaming 更通用 |
| `RtmpServerClient` | 单个客户端 | `TVUIRLStreamConnection` | connection 强调连接 |
| `RtmpServerChunkStream` | Chunk 流处理器 | `TVUIRLMediaPipeline` | pipeline 强调处理流程 |
| `SettingsRtmpServer` | 服务器配置 | `TVUIRLStreamConfig` | config 更简洁 |
| `SettingsRtmpServerStream` | 单个流配置 | `TVUIRLStreamProfile` | profile 强调配置档 |
| `ByteReader` | 二进制读取 | `TVUIRLDataReader` | data 强调数据 |
| `ByteWriter` | 二进制写入 | `TVUIRLDataWriter` | data 强调数据 |
| `Amf0Encoder` | AMF0 编码 | `TVUIRLAmfEncoder` | 简化命名 |
| `Amf0Decoder` | AMF0 解码 | `TVUIRLAmfDecoder` | 简化命名 |
| `RtmpChunk` | RTMP Chunk | `TVUIRLMediaPacket` | packet 强调数据包 |
| `BitrateStats` | 码率统计 | `TVUIRLBandwidthMeter` | bandwidth 强调带宽 |
| `TargetLatenciesSynchronizer` | 延迟同步 | `TVUIRLMediaClock` | clock 强调时钟同步 |
| `VideoDecoder` | 视频解码 | `TVUIRLHardwareDecoder` | hardware 强调硬解 |

---

## 一、代码结构

```
RTMPServerObjc/
├── TVUIRLStreamConfig.h/.m               # 服务器配置（端口、streams）
├── TVUIRLBandwidthMeter.h/.m             # 码率统计
├── TVUIRLMediaClock.h/.m                 # 音视频同步时钟
├── TVUIRLDataReader.h/.m                 # 二进制读取
├── TVUIRLDataWriter.h/.m                 # 二进制写入
├── TVUIRLAmfEncoder.h/.m                 # AMF0 编码
├── TVUIRLAmfDecoder.h/.m                 # AMF0 解码
├── TVUIRLAmfValue.h/.m                   # AMF 值类型（ObjC 类层次替代 Swift enum）
├── TVUIRLMediaPacket.h/.m                # RTMP 数据包封装
├── TVUIRLProtocolMessage.h/.m            # 协议消息基类
├── TVUIRLCommandMessage.h/.m             # 命令消息
├── TVUIRLAckMessage.h/.m                 # 确认消息
├── TVUIRLFlowControl.h/.m                # 流量控制消息
├── TVUIRLVideoConfigAvc.h/.m             # AVCDecoderConfigurationRecord 解析
├── TVUIRLVideoConfigHevc.h/.m            # HEVCDecoderConfigurationRecord 解析
├── TVUIRLAudioConfig.h/.m                # AudioSpecificConfig (AAC) 解析
├── TVUIRLAudioDecoder.h/.m               # AAC → PCM 解码（AVAudioConverter）
├── TVUIRLStreamConnection.h/.m           # 客户端连接处理
├── TVUIRLMediaPipeline.h/.m              # 媒体处理管道
├── TVUIRLStreamingServer.h/.m            # 主服务器
└── TVUIRLHardwareDecoder.h/.m            # H.264/H.265 视频硬解码
```

---

## 二、Moblin RTMP Server 实现原理

### 2.1 整体架构

```
NWListener (:1935)
    │
    └── RtmpServerClient (per TCP connection)
            │
            ├── RTMP 握手 (C0+C1 → S0+S1+S2 → C2)
            │
            └── RtmpServerChunkStream (per chunk stream id)
                    │
                    ├── AMF0 命令解析 (connect, publish, createStream...)
                    │
                    ├── 视频处理 (FLV Video Tag → H.264/H.265 NAL → CVPixelBuffer)
                    │
                    └── 音频处理 (FLV Audio Tag → AAC → PCM)
```

### 2.2 RTMP 握手流程

Moblin 实现的是标准 RTMP 握手（3 步）：

```
客户端                              服务器
  │                                   │
  │────── C0 (1 byte) ──────────────→│  版本号 (恒为 3)
  │────── C1 (1536 bytes) ──────────→│  时间戳(4) + 0(4) + 随机数(1528)
  │                                   │
  │←───── S0 (1 byte) ───────────────│  版本号
  │←───── S1 (1536 bytes) ───────────│  时间戳 + 0 + 随机数
  │←───── S2 (1536 bytes) ───────────│  C1[0..3] + 0(4) + C1[8...]
  │                                   │  (S0+S1+S2 三包同时发送)
  │                                   │
  │────── C2 (1536 bytes) ──────────→│  服务器 S1 原样返回（仅作校验）
  │                                   │
  │           握手完成                │
```

**关键实现细节：**

收到 C0+C1 后，**立即**同时发送 S0+S1+S2，然后进入 `versionSent` 状态等待 C2。
S2 的内容是 C1 的时间戳字段 + 全零(4字节) + C1 的随机字段，不是 S1 原样返回。

```objc
// 收到 C0(1B) + C1(1536B) = 1537B
uint8_t version = data[0];
// assert(version == 3)

// 构造并发送 S0
uint8_t s0 = 3;
[self sendData:[NSData dataWithBytes:&s0 length:1]];

// 构造并发送 S1（时间戳全零 + 随机 1528B）
NSMutableData *s1 = [NSMutableData dataWithLength:8];
[s1 appendData:[NSData randomDataOfLength:1528]];
[self sendData:s1];

// 构造并发送 S2（C1 的时间戳 + 全零 4B + C1 的随机字段）
NSMutableData *s2 = [NSMutableData dataWithBytes:data+1 length:4]; // C1[0..3] 时间戳
uint8_t zeros[4] = {0};
[s2 appendBytes:zeros length:4];
[s2 appendBytes:data+9 length:1527];                               // C1 随机字段
[self sendData:s2];

self.state = StreamConnectionStateVersionSent;
// 接下来等待接收 C2（1536B），收到后进入 handshakeDone
```

### 2.3 Chunk 解析流程

RTMP 消息被分割为多个 Chunk，每个 Chunk 由**基础头** + **消息头** + **扩展时间戳** + **数据**组成：

**基础头格式（1-3字节）：**
```
[format(2bit) | chunk_stream_id(6bit)]             // 1 byte  (id 2-63)
[format(2bit) | 00(6bit)][chunk_stream_id - 64]    // 2 bytes (id 64-319)
[format(2bit) | 01(6bit)][chunk_stream_id(16bit)]  // 3 bytes (id 320+)
```

**消息头格式（0/3/7/11字节）：**
- Type 0（11字节）：完整消息头（timestamp、length、type、stream_id）
- Type 1（7字节）：相对时间戳 + length + type（同流内首个分片后的包）
- Type 2（3字节）：仅时间戳差值
- Type 3（0字节）：完全复用上一个 Chunk 的头

**扩展时间戳：** 当 timestamp 字段 >= 0xFFFFFF 时，额外附加 4 字节绝对时间戳。

**控制消息使用 chunk stream id = 2**（SetChunkSize、WindowAck、SetPeerBandwidth 等）。

### 2.4 AMF0 命令流程

Moblin 处理的典型命令序列：

```
1. connect (tcUrl, app, flashVer...)
   → 回复: _result (NetConnection.Connect.Success)
   → 发送: WindowAcknowledgementSize (chunk stream 2)
   → 发送: SetPeerBandwidth (chunk stream 2)
   → 发送: SetChunkSize (chunk stream 2)

2. createStream
   → 回复: _result (streamId = 1)

3. fcPublish (streamKey)
   → 无回复

4. publish (streamKey)
   → 回复: onStatus (NetStream.Publish.Start)
```

### 2.5 视频流处理（FLV Video Tag）

RTMP 视频消息（type 0x09）的 payload 是 FLV Video Tag 格式。
H.264 使用传统头，H.265 使用扩展头（FLV Enhanced），两者区分方式：

```
第一字节：
  bit7-4 = FrameType
  bit3-0 = CodecId

若 CodecId == 0xF（即最低4位全1），表示使用扩展头（H.265 走此路径）
若 CodecId == 0x7，表示 H.264
```

**H.264 传统头：**
```
[FrameType(4bit)][0x7(4bit)][AVCPacketType(1byte)][CompositionTime(3byte)][Data...]

AVCPacketType:
  0 = AVCDecoderConfigurationRecord (SPS + PPS)
  1 = AVC NAL Units
  2 = End of Sequence
```

**H.265 扩展头（DJI Action 5 Pro 使用此格式）：**
```
[FrameType(4bit)][0xF(4bit)][PacketType(1byte)][FourCC(4byte)][Data...]

PacketType:
  0 = SequenceStart（HEVCDecoderConfigurationRecord：VPS+SPS+PPS）
  1 = CodedFrames（HEVC NAL Units）
  2 = SequenceEnd

FourCC = 0x68657663 ("hevc")
```

**处理流程：**
```objc
- (void)processVideoMessage {
    uint8_t control = messageBody[0];
    uint8_t codecId = control & 0x0F;

    if (codecId == 0x07) {
        [self processH264Video];
    } else if (codecId == 0x0F) {
        // H.265 扩展头
        uint8_t packetType = messageBody[1];
        uint32_t fourCc = (messageBody[2] << 24) | (messageBody[3] << 16)
                        | (messageBody[4] << 8)  | messageBody[5];
        if (fourCc != 0x68657663) return;  // 只处理 "hevc"

        switch (packetType) {
            case 0: [self processHevcSequenceStart]; break;  // 创建 VTDecompressionSession
            case 1: [self processHevcCodedFrames];   break;  // 解码帧
            case 2: [self stopPublishing];            break;
        }
    }
}
```

**H.265 序列头解析：**
```objc
- (void)processHevcSequenceStart {
    // messageBody[6...] = HEVCDecoderConfigurationRecord
    NSData *hvcC = [messageBody subdataWithRange:NSMakeRange(6, messageBody.length - 6)];
    TVUIRLVideoConfigHevc *config = [[TVUIRLVideoConfigHevc alloc] initWithHvcC:hvcC];

    CMVideoFormatDescriptionRef formatDesc = NULL;
    [config makeFormatDescription:&formatDesc];

    [self.hardwareDecoder startWithFormatDescription:formatDesc];
}
```

### 2.6 音频流处理（FLV Audio Tag）

RTMP 音频消息（type 0x08）的 payload 是 FLV Audio Tag 格式：

```
[SoundFormat(4bit)][SoundRate(2bit)][SoundSize(1bit)][SoundType(1bit)][AACPacketType(1byte)][Data...]

SoundFormat: 0xA = AAC
AACPacketType: 0 = AudioSpecificConfig（序列头）, 1 = Raw AAC
```

序列头用于创建 `AVAudioConverter`（AAC → PCM），Raw 包送入 `AVAudioConverter` 解码。

---

## 三、逐文件移植说明

### 3.1 TVUIRLStreamConfig.h/.m

**功能：** 服务器配置

| Moblin 属性 | 类型 | 说明 |
|---|---|---|
| `port` | UInt16 | 监听端口，默认 1935 |
| `streams` | [SettingsRtmpServerStream] | 流配置数组 |
| `noDelay` | Bool | TCP NoDelay 选项 |

**TVUIRLStreamProfile：**
| 属性 | 类型 | 说明 |
|---|---|---|
| `id` | NSUUID | 流唯一标识 |
| `streamKey` | NSString | 流名称（如 "dji"） |
| `latency` | int32_t | 目标延迟（毫秒），默认 2000 |

### 3.2 TVUIRLBandwidthMeter.h/.m

**功能：** 码率统计

Moblin 通过定时器（3秒间隔）统计：
- `totalBytes`：总传输字节
- `speed`：当前码率（bytes/s）

**关键实现：** 环形缓冲区存储历史数据，定时计算差值得出瞬时速度。

### 3.3 TVUIRLMediaClock.h/.m

**功能：** 音视频延迟同步

- 记录最新音/视频 Presentation Timestamp
- 动态计算目标延迟，确保音视频同步
- 调用 delegate 回调 `serverDidUpdateTargetLatencies:audioLatency:`

### 3.4 TVUIRLDataReader.h/.m

**功能：** 二进制数据读取（内部维护读偏移量）

| 方法 | 说明 |
|---|---|
| `readUInt8` | 读 1 字节 |
| `readUInt16` | 读 2 字节 (Big Endian) |
| `readUInt16Le` | 读 2 字节 (Little Endian) |
| `readUInt24` | 读 3 字节 (Big Endian) |
| `readUInt32` | 读 4 字节 (Big Endian) |
| `readUInt32Le` | 读 4 字节 (Little Endian) |
| `readDouble` | 读 8 字节 Double |
| `readUtf8Bytes:` | 读指定长度 UTF-8 字符串 |

### 3.5 TVUIRLDataWriter.h/.m

**功能：** 二进制数据写入（append 到内部 NSMutableData）

| 方法 | 说明 |
|---|---|
| `writeUInt8:` | 写 1 字节 |
| `writeUInt16:` | 写 2 字节 (Big Endian) |
| `writeUInt16Le:` | 写 2 字节 (Little Endian) |
| `writeUInt24:` | 写 3 字节 (Big Endian) |
| `writeUInt32:` | 写 4 字节 (Big Endian) |
| `writeUInt32Le:` | 写 4 字节 (Little Endian) |
| `writeDouble:` | 写 8 字节 Double |
| `writeData:` | 写 NSData |

### 3.6 TVUIRLAmfValue.h/.m

**功能：** AMF 值类型的 ObjC 表示

Moblin 使用 Swift enum with associated values（`AsValue`），ObjC 没有直接对应物。
**设计方案：** 基类 + 子类层次，配合 `TVUIRLAmfValueType` 枚举区分类型：

```objc
typedef NS_ENUM(NSInteger, TVUIRLAmfValueType) {
    TVUIRLAmfValueTypeNumber,
    TVUIRLAmfValueTypeBoolean,
    TVUIRLAmfValueTypeString,
    TVUIRLAmfValueTypeObject,     // NSDictionary<NSString *, TVUIRLAmfValue *>
    TVUIRLAmfValueTypeNull,
    TVUIRLAmfValueTypeUndefined,
    TVUIRLAmfValueTypeEcmaArray,
    TVUIRLAmfValueTypeStrictArray,
};

@interface TVUIRLAmfValue : NSObject
@property (nonatomic, readonly) TVUIRLAmfValueType type;

+ (instancetype)numberValue:(double)v;
+ (instancetype)stringValue:(NSString *)v;
+ (instancetype)objectValue:(NSDictionary<NSString *, TVUIRLAmfValue *> *)v;
+ (instancetype)boolValue:(BOOL)v;
+ (instancetype)nullValue;

- (double)doubleValue;
- (NSString *)stringValue;
- (NSDictionary<NSString *, TVUIRLAmfValue *> *)objectValue;
- (BOOL)boolValue;
@end
```

### 3.7 TVUIRLAmfEncoder.h/.m

**功能：** AMF0 编码（TVUIRLAmfValue → NSData）

支持类型：

| AMF0 Type | 标记字节 |
|---|---|
| Number | 0x00 |
| Boolean | 0x01 |
| String | 0x02 |
| Object | 0x03 |
| Null | 0x05 |
| Undefined | 0x06 |
| EcmaArray | 0x08 |
| ObjectEnd | 0x09 |
| StrictArray | 0x0A |

### 3.8 TVUIRLAmfDecoder.h/.m

**功能：** AMF0 解码（NSData → TVUIRLAmfValue）

关键方法：
- `decodeString:` - 解码字符串，失败时填充 error
- `decodeInt:` - 解码整数（AMF0 number 转 int）
- `decodeObject:` - 解码对象
- `decode:` - 解码任意值

### 3.9 TVUIRLMediaPacket.h/.m

**功能：** RTMP Chunk 封装

| 属性 | 类型 | 说明 |
|---|---|---|
| `type` | TVUIRLPacketType | Chunk 类型 (0-3) |
| `chunkStreamId` | uint16_t | Chunk 流 ID |
| `message` | TVUIRLProtocolMessage | 消息体 |

**Chunk 头编码：**
```objc
// Type 0 完整头（11字节消息头）
[basic_header(1-3)] [timestamp(3)] [length(3)] [type(1)] [stream_id(4, LE)]

// Type 1 相对头（7字节消息头）
[basic_header(1-3)] [timestamp_delta(3)] [length(3)] [type(1)]

// Type 2 仅时间戳（3字节消息头）
[basic_header(1-3)] [timestamp_delta(3)]

// Type 3 无消息头
[basic_header(1-3)]
```

### 3.10 TVUIRLProtocolMessage.h/.m 及子类

**基类 TVUIRLProtocolMessage：**
| 属性 | 类型 | 说明 |
|---|---|---|
| `type` | TVUIRLMessageType | 消息类型 |
| `streamId` | uint32_t | 流 ID |
| `timestamp` | uint32_t | 时间戳 |
| `length` | NSInteger | 消息长度 |

**子类：**
| 类名 | 消息类型值 | 说明 |
|---|---|---|
| `TVUIRLCommandMessage` | 0x14 | AMF 命令 |
| `TVUIRLAckMessage` | 0x05 | 窗口确认大小 |
| `TVUIRLFlowControl` | 0x01 | 设置 Chunk 大小 |
| `TVUIRLBandwidthConfig` | 0x06 | 设置带宽 |

### 3.11 TVUIRLVideoConfigAvc.h/.m / TVUIRLVideoConfigHevc.h/.m

**功能：** 解析 DecoderConfigurationRecord，创建 `CMVideoFormatDescription`

**TVUIRLVideoConfigAvc：**
```objc
// 解析 AVCDecoderConfigurationRecord（含 SPS + PPS）
// 输入：FLV H.264 序列头 payload（从第4字节起）
- (instancetype)initWithAvcC:(NSData *)avcC;
- (OSStatus)makeFormatDescription:(CMVideoFormatDescriptionRef *)outDesc;
```

**TVUIRLVideoConfigHevc：**
```objc
// 解析 HEVCDecoderConfigurationRecord（含 VPS + SPS + PPS）
// 输入：FLV H.265 扩展头序列 payload（从第6字节起，跳过 control+packetType+FourCC）
- (instancetype)initWithHvcC:(NSData *)hvcC;
- (OSStatus)makeFormatDescription:(CMVideoFormatDescriptionRef *)outDesc;
```

### 3.12 TVUIRLAudioConfig.h/.m

**功能：** 解析 AudioSpecificConfig（AAC 序列头），创建音频格式描述

```objc
// 输入：FLV Audio Tag payload 第3字节起（跳过 control byte + AACPacketType）
- (instancetype)initWithData:(NSData *)data;
- (AudioStreamBasicDescription)audioStreamBasicDescription;
- (AVAudioFormat *)avAudioFormat;
```

### 3.13 TVUIRLAudioDecoder.h/.m

**功能：** AAC → PCM 解码

```objc
@interface TVUIRLAudioDecoder : NSObject
- (void)configureWithAudioConfig:(TVUIRLAudioConfig *)config;
- (void)decodeAudioData:(NSData *)aacData timestamp:(uint32_t)timestamp;
@property (nonatomic, weak) id<TVUIRLAudioDecoderDelegate> delegate;
@end

@protocol TVUIRLAudioDecoderDelegate <NSObject>
- (void)audioDecoder:(TVUIRLAudioDecoder *)decoder
   didDecodeSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end
```

**实现：** 使用 `AVAudioConverter` 将 AAC raw frame 转 PCM，
再通过 `CMAudioSampleBufferCreateWithPacketDescriptions` 打包为 `CMSampleBuffer`。

### 3.14 TVUIRLStreamConnection.h/.m

**功能：** 单个客户端 TCP 连接处理

**状态机：**
```
uninitialized → versionSent → ackSent → handshakeDone
```

**正确握手流程：**
1. 接收 C0 + C1（1537 字节）
2. **立即**同时发送 S0 + S1 + S2（三包一起发出）
3. 进入 `versionSent` 状态，等待接收 C2（1536 字节）
4. 收到 C2 后进入 `ackSent`，随即发送初始控制消息
5. 进入 `handshakeDone` 状态，开始解析 Chunk

**关键属性：**
| 属性 | 类型 | 说明 |
|---|---|---|
| `chunkSizeToClient` | NSInteger | 服务器→客户端 chunk 大小，默认 128 |
| `chunkSizeFromClient` | NSInteger | 客户端→服务器 chunk 大小，默认 128 |
| `windowAcknowledgementSize` | NSInteger | 窗口确认大小，默认 2,500,000 |
| `streamKey` | NSString | 当前流的 key |
| `latency` | int32_t | 延迟补偿（毫秒） |

### 3.15 TVUIRLMediaPipeline.h/.m

**功能：** 解析单个 Chunk Stream 的媒体数据

**处理的消息类型：**
| 类型 | 值 | 处理方法 |
|---|---|---|
| AMF0 Command | 0x14 | `processCommandMessage` |
| AMF0 Data | 0x12 | `processDataMessage` |
| Chunk Size | 0x01 | `processChunkSizeMessage` |
| Window Ack | 0x05 | `processWindowAckMessage` |
| Video | 0x09 | `processVideoMessage` |
| Audio | 0x08 | `processAudioMessage` |

**视频消息路由（区分 H.264 / H.265）：**
```objc
- (void)processVideoMessage {
    uint8_t control = ((uint8_t *)messageBody.bytes)[0];
    uint8_t codecId = control & 0x0F;

    if (codecId == 0x07) {
        // H.264 传统路径
        uint8_t avcPacketType = ((uint8_t *)messageBody.bytes)[1];
        if (avcPacketType == 0) [self processAvcSequenceStart];
        else if (avcPacketType == 1) [self processAvcCodedFrames];
    } else if (codecId == 0x0F) {
        // H.265 扩展头路径（DJI Action 5 Pro 使用此格式）
        uint8_t packetType = ((uint8_t *)messageBody.bytes)[1];
        uint32_t fourCc = ntohl(*(uint32_t *)(messageBody.bytes + 2));
        if (fourCc != 0x68657663) return;  // "hevc"

        if (packetType == 0)      [self processHevcSequenceStart];
        else if (packetType == 1) [self processHevcCodedFrames];
        else if (packetType == 2) [self.connection stopWithReason:@"stream ended"];
    }
}
```

**AMF 命令解析流程（publish）：**
```objc
// 1. decodeString → "publish"
// 2. decodeInt   → transaction_id
// 3. decodeObject → 命令参数（通常为 null）
// 4. decode      → stream_key（字符串）
```

### 3.16 TVUIRLStreamingServer.h/.m

**功能：** 主服务器，管理所有客户端连接

**核心职责：**
- 监听 1935 端口，每个新连接创建 `TVUIRLStreamConnection` 实例
- 定时清理超时连接（10秒无数据）
- listener 失败时自动重建
- 分发 delegate 回调

**Delegate 协议（单相机，不携带 cameraId）：**
```objc
@protocol TVUIRLStreamingServerDelegate <NSObject>
- (void)serverDidStartPublishing:(NSString *)streamKey;
- (void)serverDidStopPublishing:(NSString *)streamKey reason:(NSString *)reason;
- (void)serverDidReceiveVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)serverDidReceiveAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)serverDidUpdateStats:(TVUIRLBandwidthMeter *)meter;
@end
```

> **注：** Moblin 原始 delegate 每个回调带 `cameraId: UUID`（支持多相机）。
> 此移植目标为单相机场景，故省略 cameraId；如后续需要多相机，需补充该参数。

### 3.17 TVUIRLHardwareDecoder.h/.m

**功能：** H.264/H.265 视频硬解码

**实现要点：**
1. 通过 `TVUIRLVideoConfigAvc` 或 `TVUIRLVideoConfigHevc` 创建 `CMVideoFormatDescription`
2. 使用 `VTDecompressionSessionCreate` 建立硬解码会话
3. 逐 NAL Unit 调用 `VTDecompressionSessionDecodeFrame`，输出 `CVPixelBuffer`
4. 将 `CVPixelBuffer` 包装为 `CMSampleBuffer` 后回调 delegate

---

## 四、网络层实现方案

### 方案：使用 GCDAsyncSocket（CocoaAsyncSocket）

API 封装友好，参考代码丰富，适合快速实现阶段。

**引入方式：**
```ruby
# Podfile
pod 'CocoaAsyncSocket', '~> 7.6'
```

**TVUIRLStreamingServer 核心代码结构：**
```objc
@interface TVUIRLStreamingServer : NSObject <GCDAsyncSocketDelegate>
@property (nonatomic, weak) id<TVUIRLStreamingServerDelegate> delegate;
@property (nonatomic, strong) TVUIRLStreamConfig *config;
@property (nonatomic, strong) GCDAsyncSocket *listenerSocket;
@property (nonatomic, strong) NSMutableArray<TVUIRLStreamConnection *> *connections;

- (void)start;
- (void)stop;
- (BOOL)isStreamConnected:(NSString *)streamKey;
@end
```

> **后续迁移路径：** 如需去除 CocoaPods 依赖，可替换为原生 `Network.framework`
> （`NWListener` / `NWConnection`，iOS 12+，支持 ObjC），接口层保持不变即可。

---

## 五、文件与 Moblin 源文件对应表

| RTMPServerObjc 文件 | Moblin/Swift 源文件 |
|---|---|
| `TVUIRLStreamConfig.h/.m` | `SettingsRtmpServer.swift` |
| `TVUIRLBandwidthMeter.h/.m` | `HaishinKit/Util/BitrateStats.swift` |
| `TVUIRLMediaClock.h/.m` | `HaishinKit/Media/TargetLatenciesSynchronizer.swift` |
| `TVUIRLDataReader.h/.m` | `HaishinKit/Util/ByteReader.swift` |
| `TVUIRLDataWriter.h/.m` | `HaishinKit/Util/ByteWriter.swift` |
| `TVUIRLAmfEncoder.h/.m` | `HaishinKit/Rtmp/Amf/Amf.swift` (Encoder 部分) |
| `TVUIRLAmfDecoder.h/.m` | `HaishinKit/Rtmp/Amf/Amf.swift` (Decoder 部分) |
| `TVUIRLAmfValue.h/.m` | `HaishinKit/Rtmp/Amf/Amf.swift` (AsValue enum) |
| `TVUIRLMediaPacket.h/.m` | `HaishinKit/Rtmp/RtmpChunk.swift` |
| `TVUIRLProtocolMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpMessage.swift` |
| `TVUIRLCommandMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpCommandMessage.swift` |
| `TVUIRLAckMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpAcknowledgementMessage.swift` |
| `TVUIRLFlowControl.h/.m` | `HaishinKit/Rtmp/Message/RtmpSetChunkSizeMessage.swift` |
| `TVUIRLBandwidthConfig.h/.m` | `HaishinKit/Rtmp/Message/RtmpSetPeerBandwidthMessage.swift` |
| `TVUIRLVideoConfigAvc.h/.m` | `HaishinKit/Mpeg/Avc/MpegTsVideoConfigAvc.swift` |
| `TVUIRLVideoConfigHevc.h/.m` | `HaishinKit/Mpeg/Hevc/MpegTsVideoConfigHevc.swift` |
| `TVUIRLAudioConfig.h/.m` | `HaishinKit/Mpeg/MpegTsAudioConfig.swift` |
| `TVUIRLAudioDecoder.h/.m` | （内联于 `RtmpServerChunkStream.swift` 音频处理部分） |
| `TVUIRLStreamConnection.h/.m` | `RtmpServerClient.swift` |
| `TVUIRLMediaPipeline.h/.m` | `RtmpServerChunkStream.swift` |
| `TVUIRLStreamingServer.h/.m` | `RtmpServer.swift` |
| `TVUIRLHardwareDecoder.h/.m` | `HaishinKit/Codec/VideoDecoder.swift` |

---

## 六、实施顺序（建议）

1. **第一阶段：基础设施**
   - `TVUIRLDataReader.h/.m`
   - `TVUIRLDataWriter.h/.m`
   - `TVUIRLBandwidthMeter.h/.m`

2. **第二阶段：AMF 协议**
   - `TVUIRLAmfValue.h/.m`（先设计好 ObjC 类型表示）
   - `TVUIRLAmfEncoder.h/.m`
   - `TVUIRLAmfDecoder.h/.m`

3. **第三阶段：RTMP 协议消息**
   - `TVUIRLProtocolMessage.h/.m`
   - `TVUIRLMediaPacket.h/.m`
   - 各消息子类（CommandMessage / AckMessage / FlowControl / BandwidthConfig）

4. **第四阶段：媒体格式解析**
   - `TVUIRLVideoConfigAvc.h/.m`
   - `TVUIRLVideoConfigHevc.h/.m`
   - `TVUIRLAudioConfig.h/.m`

5. **第五阶段：核心服务器**
   - `TVUIRLStreamConfig.h/.m`
   - `TVUIRLMediaClock.h/.m`
   - `TVUIRLStreamConnection.h/.m`（含握手状态机）
   - `TVUIRLMediaPipeline.h/.m`（含 FLV 视频扩展头路由）
   - `TVUIRLStreamingServer.h/.m`

6. **第六阶段：解码器**
   - `TVUIRLHardwareDecoder.h/.m`（视频 VTDecompressionSession）
   - `TVUIRLAudioDecoder.h/.m`（音频 AVAudioConverter）

---

## 七、关键算法说明

### 7.1 RTMP Chunk 拆包

一个完整消息可能被分割成多个 Chunk：

```objc
// 消息长度 10000 bytes，chunk_size = 128
// → 需要 79 个 chunks（第1个 Type 0，后78个 Type 3）
// 第1块: 128B；第2~78块: 各 128B；第79块: 剩余 10000 - 78*128 = 16B

// Type 0 头只在第一个 chunk 出现（含完整消息头）
// Type 3 头表示复用上一个 chunk 的全部头信息
```

### 7.2 时间戳计算

Moblin 使用相对时间戳累加：

```objc
if (isAbsoluteTimestamp) {
    mediaTimestamp = messageTimestamp;
} else {
    mediaTimestamp += messageTimestamp;
}
if (mediaTimestampZero == -1) {
    mediaTimestampZero = mediaTimestamp;
}
```

### 7.3 视频帧时间戳

```objc
CMTime presentationTimeStamp = CMTimeMake(
    videoTimestamp - mediaTimestampZero + basePresentationTimeStamp + latency,
    1000   // timebase = milliseconds
);
```

---

## 八、测试验证点

1. **RTMP 握手**：Wireshark 抓包确认 S0+S1+S2 同帧发出，C2 收到后进入 handshakeDone
2. **AMF 命令解析**：connect → _result → createStream → publish → onStatus
3. **H.265 序列头**：确认 FLV 扩展头路由正确，`TVUIRLVideoConfigHevc` 能生成有效 FormatDescription
4. **视频解码**：H.264 和 H.265 均能解码出帧，CMSampleBuffer 时间戳连续
5. **音频解码**：AAC 序列头解析后 AVAudioConverter 正常工作，PCM 回调正确
6. **码率统计**：带宽计数与实际推流码率吻合
7. **多客户端**：同一 streamKey 只允许一个连接，第二个连接发起时断开旧连接

---

*生成时间：2026-04-27（修订：2026-04-28）*
*参考：Moblin RTMPServer (MIT License, eerimoq/moblin)*
