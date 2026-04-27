# RTMPServerObjc 移植计划

**源项目：** Moblin (eerimoq/moblin) - MIT License
**目标项目：** TVUIRLSDK iOS
**语言：** Objective-C
**渲染路径：** 不需要 Metal，只保留 CMSampleBuffer 回调

---

## 一、代码结构

```
RTMPServerObjc/
├── TVUIRLSettingsRtmpServer.h/.m          # 服务器配置
├── TVUIRLBitrateStats.h/.m                # 码率统计
├── TVUIRLTargetLatenciesSynchronizer.h/.m # 音视频同步
├── TVUIRLByteReader.h/.m                  # 二进制读取
├── TVUIRLByteWriter.h/.m                  # 二进制写入
├── TVUIRLAmf0Encoder.h/.m                 # AMF0 编码
├── TVUIRLAmf0Decoder.h/.m                 # AMF0 解码
├── TVUIRLAsValue.h/.m                     # AMF 值类型
├── TVUIRLRtmpChunk.h/.m                   # RTMP Chunk
├── TVUIRLRtmpMessage.h/.m                 # RTMP 消息基类
├── TVUIRLRtmpCommandMessage.h/.m         # 命令消息
├── TVUIRLRtmpWindowAckMessage.h/.m       # 窗口确认
├── TVUIRLRtmpSetChunkSizeMessage.h/.m    # Chunk大小
├── TVUIRLRtmpSetPeerBandwidthMessage.h/.m # 带宽设置
├── TVUIRLRtmpAckMessage.h/.m             # 确认消息
├── TVUIRLRtmpServerClient.h/.m           # 客户端连接
├── TVUIRLRtmpServerChunkStream.h/.m      # Chunk流处理
├── TVUIRLRtmpServer.h/.m                  # 主服务器
└── TVUIRLVideoDecoder.h/.m              # 视频解码器
```

---

## 二、Moblin RTMP Server 实现原理

### 2.1 整体架构

```
NWListener (:1935)
    │
    └── RtmpServerClient (per TCP connection)
            │
            ├── RTMP 握手 (C0/S0 → C1/S1 → C2/S2)
            │
            └── RtmpServerChunkStream (per chunk stream id)
                    │
                    ├── AMF0 命令解析 (connect, publish, createStream...)
                    │
                    ├── 视频处理 (H.264/H.265 NAL → CVPixelBuffer)
                    │
                    └── 音频处理 (AAC → PCM)
```

### 2.2 RTMP 握手流程

Moblin 实现的是标准 RTMP 握手（3 步）：

```
客户端                              服务器
  │                                   │
  │────────── C0 (1 byte) ──────────→│  版本号 (恒为 3)
  │────────── C1 (1536 bytes) ──────→│  时间戳(4) + 0(4) + 随机数(1528)
  │                                   │
  │←───────── S0 (1 byte) ───────────│  版本号
  │←───────── S1 (1536 bytes) ──────│  时间戳 + 0 + 随机数
  │←───────── S2 (1536 bytes) ──────│  客户端 C1 原样返回
  │                                   │
  │────────── C2 (1536 bytes) ──────→│  服务器 S1 原样返回
  │                                   │
  │          握手完成                 │
```

### 2.3 Chunk 解析流程

RTMP 消息被分割为多个 Chunk，每个 Chunk 由**基础头** + **消息头** + **扩展时间戳** + **数据**组成：

**基础头格式（1-3字节）：**
```
[format(2bit) | chunk_stream_id(6bit)]  // 1 byte (id 0-63)
[format(2bit) | 00(6bit)][chunk_stream_id] // 2 bytes (id 64-319)
[format(2bit) | 01(6bit)][chunk_stream_id(16bit)] // 3 bytes (id 320+)
```

**消息头格式（0/3/7/11字节）：**
- Type 0（11字节）：完整消息头（stream_id、timestamp、length、type）
- Type 1（7字节）：相对时间戳（用于消息分割后的第一个chunk以外）
- Type 2（3字节）：仅有时间戳
- Type 3（0字节）：与上一个 Chunk 完全相同

### 2.4 AMF0 命令流程

Moblin 处理的典型命令序列：

```
1. connect (tcUrl, app, flashVer...)
   → 回复: _result (NetConnection.Connect.Success)

2. createStream
   → 回复: _result (streamId = 1)

3. fcPublish (streamKey)
   → 无回复

4. publish (streamKey)
   → 回复: onStatus (NetStream.Publish.Start)
```

### 2.5 视频流处理

Moblin 支持 H.264 和 H.265（HEVC）两种编码：

**H.264 (AVC)：**
```
AVCDecoderConfigurationRecord (seq header)
    ├── SPS (Sequence Parameter Set)
    ├── PPS (Picture Parameter Set)
    └── SEI (Supplemental Enhancement Information)

NAL Units
    ├── IDR Frame (关键帧)
    ├── I Frame
    ├── P Frame
    └── AUD (Access Unit Delimiter)
```

**H.265 (HEVC)：**
```
HEVCDecoderConfigurationRecord (seq header)
    ├── VPS (Video Parameter Set)
    ├── SPS (Sequence Parameter Set)
    ├── PPS (Picture Parameter Set)
    └── SEI (Supplemental Enhancement Information)
```

Moblin 通过 `VideoDecoder` 类使用 `VTDecompressionSession` 进行硬解码，输出 `CVPixelBuffer`。

---

## 三、逐文件移植说明

### 3.1 TVUIRLSettingsRtmpServer.h/.m

**功能：** 服务器配置

| Swift 属性 | 类型 | 说明 |
|---|---|---|
| `port` | UInt16 | 监听端口，默认 1935 |
| `streams` | [SettingsRtmpServerStream] | 流配置数组 |
| `noDelay` | Bool | TCP NoDelay 选项 |

**TVUIRLSettingsRtmpServerStream：**
| Swift 属性 | 类型 | 说明 |
|---|---|---|
| `id` | UUID | 流唯一标识 |
| `streamKey` | String | 流名称（如 "dji"） |
| `latency` | Int32 | 目标延迟（毫秒），默认 2000 |

### 3.2 TVUIRLBitrateStats.h/.m

**功能：** 码率统计

Moblin 通过定时器（3秒间隔）统计：
- `totalBytes`：总传输字节
- `speed`：当前码率（bytes/s）

**关键实现：** 环形缓冲区存储历史数据，定时计算差值得出瞬时速度。

### 3.3 TVUIRLTargetLatenciesSynchronizer.h/.m

**功能：** 音视频延迟同步

- 记录最新音/视频 Presentation Timestamp
- 动态计算目标延迟，确保音视频同步
- 调用 `delegate.rtmpServerSetTargetLatencies`

### 3.4 TVUIRLByteReader.h/.m

**功能：** 二进制数据读取

| 方法 | 说明 |
|---|---|
| `readUInt8` | 读 1 字节 |
| `readUInt16` | 读 2 字节 (Big Endian) |
| `readUInt16Le` | 读 2 字节 (Little Endian) |
| `readUInt24` | 读 3 字节 (Big Endian) |
| `readUInt32` | 读 4 字节 (Big Endian) |
| `readUInt32Le` | 读 4 字节 (Little Endian) |
| `readDouble` | 读 8 字节 Double |
| `readUtf8Bytes` | 读 UTF-8 字符串 |

### 3.5 TVUIRLByteWriter.h/.m

**功能：** 二进制数据写入

| 方法 | 说明 |
|---|---|
| `writeUInt8` | 写 1 字节 |
| `writeUInt16` | 写 2 字节 (Big Endian) |
| `writeUInt16Le` | 写 2 字节 (Little Endian) |
| `writeUInt24` | 写 3 字节 (Big Endian) |
| `writeUInt32` | 写 4 字节 (Big Endian) |
| `writeUInt32Le` | 写 4 字节 (Little Endian) |
| `writeDouble` | 写 8 字节 Double |
| `writeBytes` | 写 Data |

### 3.6 TVUIRLAmf0Encoder.h/.m

**功能：** AMF0 编码

支持类型：
| AMF0 Type | 值 |
|---|---|
| Number | 0x00 |
| Boolean | 0x01 |
| String | 0x02 |
| Object | 0x03 |
| Null | 0x05 |
| Undefined | 0x06 |
| EcmaArray | 0x08 |
| StrictArray | 0x0A |

### 3.7 TVUIRLAmf0Decoder.h/.m

**功能：** AMF0 解码

关键方法：
- `decodeString` - 解码字符串
- `decodeInt` - 解码整数（AMF0 number 转 int）
- `decodeObject` - 解码对象
- `decode` - 解码任意值

### 3.8 TVUIRLRtmpChunk.h/.m

**功能：** RTMP Chunk 封装

| 属性 | 类型 | 说明 |
|---|---|---|
| `type` | RtmpChunkType | Chunk 类型 (0-3) |
| `chunkStreamId` | UInt16 | Chunk 流 ID |
| `message` | RtmpMessage | 消息体 |

**Chunk 头编码：**
```objc
// Type 0 完整头
[basic_header(1-3)] [timestamp(3)] [length(3)] [type(1)] [stream_id(4)]

// Type 1 相对头
[basic_header(1-3)] [timestamp(3)] [length(3)] [type(1)]

// Type 2 仅时间戳
[basic_header(1-3)] [timestamp(3)]

// Type 3 无头
[basic_header(1-3)] // 复用上一个 chunk 的 header
```

### 3.9 TVUIRLRtmpMessage.h/.m 及子类

**基类 RtmpMessage：**
| 属性 | 类型 | 说明 |
|---|---|---|
| `type` | RtmpMessageType | 消息类型 |
| `streamId` | UInt32 | 流 ID |
| `timestamp` | UInt32 | 时间戳 |
| `length` | Int | 消息长度 |

**子类：**
| 类名 | 消息类型 | 说明 |
|---|---|---|
| `TVUIRLRtmpCommandMessage` | 0x14 | AMF 命令 |
| `TVUIRLRtmpWindowAckMessage` | 0x05 | 窗口确认大小 |
| `TVUIRLRtmpSetChunkSizeMessage` | 0x01 | 设置 Chunk 大小 |
| `TVUIRLRtmpSetPeerBandwidthMessage` | 0x06 | 设置带宽 |
| `TVUIRLRtmpAckMessage` | 0x02 | 确认消息 |

### 3.10 TVUIRLRtmpServerClient.h/.m

**功能：** 单个客户端 TCP 连接处理

**状态机：**
```
uninitialized → versionSent → ackSent → handshakeDone
```

**核心流程：**
1. 接收 C0 + C1（1537 字节）
2. 发送 S0 + S1
3. 接收 C2
4. 发送 S2
5. 进入 `handshakeDone` 状态，开始解析 Chunk

**关键属性：**
| 属性 | 类型 | 说明 |
|---|---|---|
| `chunkSizeToClient` | Int | 服务器→客户端 chunk 大小，默认 128 |
| `chunkSizeFromClient` | Int | 客户端→服务器 chunk 大小，默认 128 |
| `windowAcknowledgementSize` | Int | 窗口确认大小，默认 2,500,000 |
| `streamKey` | NSString | 当前流的 key |
| `latency` | Int32 | 延迟补偿（毫秒） |

### 3.11 TVUIRLRtmpServerChunkStream.h/.m

**功能：** 解析单个 Chunk Stream

**处理的消息类型：**
| 类型 | 值 | 处理 |
|---|---|---|
| AMF0 Command | 0x14 | `processMessageAmf0Command` |
| AMF0 Data | 0x12 | `processMessageAmf0Data` |
| Chunk Size | 0x01 | `processMessageChunkSize` |
| Window Ack | 0x05 | `processMessageWindowAck` |
| Video | 0x09 | `processMessageVideo` |
| Audio | 0x08 | `processMessageAudio` |

**AMF 命令解析：**
```objc
// publish 命令流程
1. decodeString() → "publish"
2. decodeInt() → transaction_id
3. decodeObject() → 命令参数
4. decode() → stream_key
```

### 3.12 TVUIRLRtmpServer.h/.m

**功能：** 主服务器，管理所有客户端连接

**核心实现：**
```objc
// 使用 GCDAsyncSocket 或原生 CFSocket 监听 1935 端口
// 每个新连接创建 TVUIRLRtmpServerClient 实例
// 持有所有 client 数组，负责：
// 1. 定时清理超时 client（10秒无数据）
// 2. listener 失败时自动重连
// 3. 分发 delegate 回调
```

**Delegate 协议：**
```objc
@protocol TVUIRLRtmpServerDelegate <NSObject>
- (void)rtmpServerDidStartPublish:(NSString *)streamKey;
- (void)rtmpServerDidStopPublish:(NSString *)streamKey reason:(NSString *)reason;
- (void)rtmpServerDidReceiveVideoBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)rtmpServerDidReceiveAudioBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)rtmpServerDidUpdateStats:(TVUIRLBitrateStatsInstant *)stats;
@end
```

### 3.13 TVUIRLVideoDecoder.h/.m

**功能：** H.264/H.265 视频解码

**实现要点：**
1. 解析 `AVCDecoderConfigurationRecord` 或 `HEVCDecoderConfigurationRecord`
2. 创建 `VTDecompressionSession`
3. 解码 NAL Unit，输出 `CVPixelBuffer`
4. 回调 `handleVideoFrame:imageBuffer:` 或 `handleVideoFrame:sampleBuffer:`

---

## 四、网络层实现方案

### 方案：使用 GCDAsyncSocket（CocoaAsyncSocket）

由于原生 `CFSocket` 封装较复杂，推荐使用成熟的 **CocoaAsyncSocket** 库：

**引入方式：**
```ruby
# Podfile
pod 'CocoaAsyncSocket', '~> 7.6'
```

**TVUIRLRtmpServer 核心代码结构：**
```objc
@interface TVUIRLRtmpServer : NSObject <GCDAsyncSocketDelegate>
@property (nonatomic, weak) id<TVUIRLRtmpServerDelegate> delegate;
@property (nonatomic, strong) GCDAsyncSocket *listenerSocket;
@property (nonatomic, strong) NSMutableArray<TVUIRLRtmpServerClient *> *clients;
@property (nonatomic, strong) TVUIRLSettingsRtmpServer *settings;

// 方法
- (void)start;
- (void)stop;
- (BOOL)isStreamConnected:(NSString *)streamKey;
@end
```

---

## 五、文件与 Swift 源文件对应表

| RTMPServerObjc 文件 | Moblin/Swift 源文件 |
|---|---|
| `TVUIRLSettingsRtmpServer.h/.m` | `SettingsRtmpServer.swift` |
| `TVUIRLBitrateStats.h/.m` | `HaishinKit/Util/BitrateStats.swift` |
| `TVUIRLTargetLatenciesSynchronizer.h/.m` | `HaishinKit/Media/TargetLatenciesSynchronizer.swift` |
| `TVUIRLByteReader.h/.m` | `HaishinKit/Util/ByteReader.swift` |
| `TVUIRLByteWriter.h/.m` | `HaishinKit/Util/ByteWriter.swift` |
| `TVUIRLAmf0Encoder.h/.m` | `HaishinKit/Rtmp/Amf/Amf.swift` (Encoder 部分) |
| `TVUIRLAmf0Decoder.h/.m` | `HaishinKit/Rtmp/Amf/Amf.swift` (Decoder 部分) |
| `TVUIRLAsValue.h/.m` | `HaishinKit/Rtmp/Amf/Amf.swift` (AsValue 等类型) |
| `TVUIRLRtmpChunk.h/.m` | `HaishinKit/Rtmp/RtmpChunk.swift` |
| `TVUIRLRtmpMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpMessage.swift` |
| `TVUIRLRtmpCommandMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpCommandMessage.swift` |
| `TVUIRLRtmpWindowAckMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpWindowAcknowledgementSizeMessage.swift` |
| `TVUIRLRtmpSetChunkSizeMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpSetChunkSizeMessage.swift` |
| `TVUIRLRtmpSetPeerBandwidthMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpSetPeerBandwidthMessage.swift` |
| `TVUIRLRtmpAckMessage.h/.m` | `HaishinKit/Rtmp/Message/RtmpAcknowledgementMessage.swift` |
| `TVUIRLRtmpServerClient.h/.m` | `RtmpServerClient.swift` |
| `TVUIRLRtmpServerChunkStream.h/.m` | `RtmpServerChunkStream.swift` |
| `TVUIRLRtmpServer.h/.m` | `RtmpServer.swift` |
| `TVUIRLVideoDecoder.h/.m` | `HaishinKit/Codec/VideoDecoder.swift` |

---

## 六、实施顺序（建议）

1. **第一阶段：基础设施**
   - `TVUIRLByteReader.h/.m`
   - `TVUIRLByteWriter.h/.m`
   - `TVUIRLBitrateStats.h/.m`

2. **第二阶段：AMF 协议**
   - `TVUIRLAsValue.h/.m`
   - `TVUIRLAmf0Encoder.h/.m`
   - `TVUIRLAmf0Decoder.h/.m`

3. **第三阶段：RTMP 消息**
   - `TVUIRLRtmpMessage.h/.m`
   - `TVUIRLRtmpChunk.h/.m`
   - 各消息子类

4. **第四阶段：核心服务器**
   - `TVUIRLSettingsRtmpServer.h/.m`
   - `TVUIRLTargetLatenciesSynchronizer.h/.m`
   - `TVUIRLRtmpServerClient.h/.m`
   - `TVUIRLRtmpServerChunkStream.h/.m`
   - `TVUIRLRtmpServer.h/.m`

5. **第五阶段：视频解码**
   - `TVUIRLVideoDecoder.h/.m`

---

## 七、关键算法说明

### 7.1 RTMP Chunk 拆包

一个完整消息可能被分割成多个 Chunk：

```objc
// 消息长度 10000 bytes，chunk_size = 128
// → 需要 78 个 chunks (77 * 128 + 64)

// Type 0 header 只在第一个 chunk 出现
// Type 3 header 表示复用上一个 chunk 的 header
```

### 7.2 时间戳计算

Moblin 使用相对时间戳累加：

```objc
if (isAbsoluteTimeStamp) {
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
    videoTimestamp + basePresentationTimeStamp + latency,
    1000
);
```

---

## 八、测试验证点

1. **RTMP 握手**：Wireshark 抓包确认 C0/C1/C2 正确
2. **AMF 命令解析**：connect → _result → createStream → publish
3. **视频解码**：确认 H.264/H.265 均可解码出帧
4. **码率统计**：确认 bitrate 计算正确
5. **多客户端**：同一 streamKey 只允许一个客户端

---

*生成时间：2026-04-27*
*参考：Moblin RTMPServer (MIT License)*
