# IngestObjc 移植计划

**源项目：** HaishinKit (DJIStreamDemo/Ingest)
**目标项目：** TVUIRL iOS
**语言：** Objective-C
**前置条件：** RTMPServerObjc 已完成（RTMPServerObjc_Plan.md）
**命名策略：** 复用 RTMPServerObjc 中已建的 `TVUIRL*` 前缀类，新建类使用 `TVUIRL*` 前缀，命名与原 Swift 文件相似但不同

---

## 零、已有迁移说明

RTMPServerObjc_Plan.md 已移植以下组件，复用于 Ingest 模块：

| 已移植类 | 原 Swift 文件 | 用途 |
|---|---|---|
| `TVUIRLDataReader` | `HaishinKit/Util/ByteReader.swift` | 二进制读取 |
| `TVUIRLDataWriter` | `HaishinKit/Util/ByteWriter.swift` | 二进制写入 |
| `TVUIRLBandwidthMeter` | `HaishinKit/Util/BitrateStats.swift` | 码率统计 |
| `TVUIRLMediaClock` | `HaishinKit/Media/TargetLatenciesSynchronizer.swift` | 音视频同步 |
| `TVUIRLHardwareDecoder` | `HaishinKit/Codec/VideoDecoder.swift` | 视频硬解码 |
| `TVUIRLVideoConfigAvc` | `HaishinKit/Mpeg/Avc/MpegTsVideoConfigAvc.swift` | AVC 格式解析 |
| `TVUIRLVideoConfigHevc` | `HaishinKit/Mpeg/Hevc/MpegTsVideoConfigHevc.swift` | HEVC 格式解析 |
| `TVUIRLAmfValue/Encoder/Decoder` | `HaishinKit/Rtmp/Amf/Amf.swift` | AMF0 编解码 |
| `TVUIRLMediaPacket` | `HaishinKit/Rtmp/RtmpChunk.swift` | Chunk 封装 |
| 各 `TVUIRL*Message` | `HaishinKit/Rtmp/Message/*.swift` | RTMP 消息类型 |

---

## 一、Ingest 模块架构

```
RTMPIngestController (已 ObjC)
    │
    ├── TVUIRLStreamPublisher (新建)
    │       │
    │       ├── TVUIRLRtmpPublisher (新建)     ← RTMP 发布端
    │       │       │
    │       │       ├── TVUIRLFlvTagAssembler (新建)  ← FLV Tag 组装
    │       │       ├── TVUIRLMediaClock (已有)       ← 音视频同步
    │       │       └── TVUIRLBandwidthMeter (已有)   ← 码率统计
    │       │
    │       └── TVUIRLPreviewController (新建)  ← 预览控制器（替代 MetalPreviewView）
    │
    └── RTMPIngestController (已 Objc，绑定新层)
```

---

## 二、需要新建/迁移的文件

### 2.1 TVUIRLFlvTagAssembler.h/.m

**原 Swift：** 无直接对应（内联于 `RtmpServerChunkStream` 的组装逻辑）

**功能：** 将 H.264/H.265 NAL Units 和 AAC Samples 组装为 FLV Video/Audio Tag，供 RTMP 发送

**Video Tag 格式（H.264 传统头）：**
```
[FrameType(4bit)][CodecId=0x7(4bit)][AVCPacketType(1byte)][CompositionTime(3byte)][Data...]

AVCPacketType:
  0 = AVCDecoderConfigurationRecord (SPS+PPS)
  1 = AVC NAL Units (需添加 StartCode 0x00000001)
  2 = End of Sequence
```

**Video Tag 格式（H.265 扩展头）：**
```
[FrameType(4bit)][CodecId=0xF(4bit)][PacketType(1byte)][FourCC="hevc"(4byte)][Data...]

PacketType:
  0 = SequenceStart（HEVCDecoderConfigurationRecord：VPS+SPS+PPS）
  1 = CodedFrames（HEVC NAL Units，需添加 StartCode）
  2 = SequenceEnd
```

**Audio Tag 格式：**
```
[SoundFormat=0xA(4bit)][SoundRate(2bit)][SoundSize(1bit)][SoundType(1bit)][AACPacketType(1byte)][Data...]

AACPacketType:
  0 = AudioSpecificConfig
  1 = Raw AAC frame
```

**关键方法：**
| 方法 | 说明 |
|---|---|
| `assembleAvcSequenceHeader:sps:pps:` | 封装 H.264 序列头（AVCDecoderConfigurationRecord） |
| `assembleHevcSequenceHeader:vps:sps:pps:` | 封装 H.265 序列头（HEVCDecoderConfigurationRecord） |
| `assembleAvcNalUnits:presentationTimestamp:` | 封装 H.264 NAL Units（添加 StartCode） |
| `assembleHevcNalUnits:presentationTimestamp:` | 封装 H.265 NAL Units（添加 StartCode） |
| `assembleAudioSpecificConfig:` | 封装 AAC 序列头 |
| `assembleAudioRawData:` | 封装 Raw AAC 数据 |

### 2.2 TVUIRLPreviewController.h/.m

**原 Swift：** `HaishinKit/Media/Video/MetalPreviewView.swift`

**功能：** Metal 预览视图的 ObjC 实现

**关键属性：**
| 属性 | 类型 | 说明 |
|---|---|---|
| `metalLayer` | CAMetalLayer | Metal 渲染层 |
| `pixelBuffer` | CVPixelBufferRef | 当前预览帧 |
| `renderQueue` | dispatch_queue_t | 渲染队列 |

**关键方法：**
| 方法 | 说明 |
|---|---|
| `enqueuePixelBuffer:` | 入队渲染 |
| `flush` | 清空渲染队列 |
| `delegate` | 设置预览回调 |

### 2.3 TVUIRLShaderProgram.h/.m

**原 Swift：** `HaishinKit/Media/Video/Shader.metal`（对应 Metal shader 代码的 ObjC 封装）

**功能：** Metal Shader 程序管理（顶点/片段着色器编译、纹理创建）

> **说明：** Metal shader (.metal 文件) 无法用 ObjC 替代，需要保留 .metal 文件，
> 但通过 ObjC 的 `MTLDevice` / `MTLLibrary` / `MTLRenderPipelineState` 管理。

```objc
@interface TVUIRLShaderProgram : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLTexture> currentTexture;

- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)createPipelineWithVertexFunction:(NSString *)vertexFunctionName
                        fragmentFunction:(NSString *)fragmentFunctionName
                                      pixelFormat:(MTLPixelFormat)pixelFormat;
- (void)renderToLayer:(CAMetalLayer *)layer;
@end
```

### 2.4 TVUIRLTextureCache.h/.m

**原 Swift：** 内联于 `MetalPreviewView.swift` 的纹理缓存逻辑

**功能：** CVPixelBuffer → MTLTexture 缓存管理

```objc
@interface TVUIRLTextureCache : NSObject
@property (nonatomic, strong) id<MTLDevice> device;

- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (id<MTLTexture>)textureForPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)flush;
@end
```

### 2.5 TVUIRLVideoEncoder.h/.m

**原 Swift：** 无直接对应（如果原 Ingest 有软编码需求）

**功能：** 视频编码（可选，取决于是否需要软编）

> **注：** 如果 Ingest 模块只需要发送已编码的视频数据，此文件可省略。

### 2.6 TVUIRLAudioEncoder.h/.m

**原 Swift：** 无直接对应（内联于其他文件的音频编码逻辑）

**功能：** 音频编码（PCM → AAC）

**实现要点：**
- 使用 `AVAudioConverter` 将 PCM 转为 AAC
- 输出 AAC raw frame，封装为 FLV Audio Tag 后发送
- 配置采样率、声道数、码率

```objc
@interface TVUIRLAudioEncoder : NSObject
@property (nonatomic, assign) NSInteger sampleRate;
@property (nonatomic, assign) NSInteger channelCount;
@property (nonatomic, assign) NSInteger bitRate;
@property (nonatomic, weak) id<TVUIRLAudioEncoderDelegate> delegate;

- (void)configureWithSampleRate:(NSInteger)sampleRate
                   channelCount:(NSInteger)channelCount
                        bitRate:(NSInteger)bitRate;
- (void)encodePCMData:(NSData *)pcmData;
- (NSData *)audioSpecificConfigData;
@end

@protocol TVUIRLAudioEncoderDelegate <NSObject>
- (void)audioEncoder:(TVUIRLAudioEncoder *)encoder
     didEncodeAudioData:(NSData *)aacData
         presentationTimestamp:(uint32_t)pts;
@end
```

### 2.7 TVUIRLRtmpPublisher.h/.m

**原 Swift：** 对应 `RtmpServer.swift` / `RtmpServerClient.swift`（但方向相反）

**功能：** RTMP 发布端（对应 RTMP Server 的接收端逻辑）

**核心职责：**
- 建立 TCP 连接（复用 CocoaAsyncSocket）
- 执行 RTMP 握手（客户端视角：发送 C0+C1 → 接收 S0+S1+S2 → 发送 C2）
- 发送 connect / createStream / publish 命令
- 组装并发送 FLV Video Tag 和 Audio Tag

**关键流程：**
```
1. TCP 连接成功后启动握手
2. 握手完成后发送 connect(app)
3. 收到 _result 后发送 createStream()
4. 收到 streamId 后发送 publish(streamKey)
5. 发送 Video Sequence Header（SPS/PPS/VPS）
6. 循环发送 Audio/Video 数据帧
```

**Delegate 协议：**
```objc
@protocol TVUIRLRtmpPublisherDelegate <NSObject>
- (void)publisherDidConnect:(TVUIRLRtmpPublisher *)publisher;
- (void)publisherDidDisconnect:(TVUIRLRtmpPublisher *)publisher reason:(NSString *)reason;
- (void)publisher:(TVUIRLRtmpPublisher *)publisher didFailWithError:(NSError *)error;
- (void)publisher:(TVUIRLRtmpPublisher *)publisher didUpdateStats:(TVUIRLBandwidthMeter *)stats;
@end
```

### 2.8 TVUIRLStreamPublisher.h/.m

**原 Swift：** 对应 `RtmpServer.swift` 的对外接口层

**功能：** 统一发布接口，封装 RTMP 发布 + 预览 + 编码

```objc
@protocol TVUIRLStreamPublisherDelegate <NSObject>
- (void)publisherDidStart:(TVUIRLStreamPublisher *)publisher;
- (void)publisherDidStop:(TVUIRLStreamPublisher *)publisher;
- (void)publisher:(TVUIRLStreamPublisher *)publisher didReceiveVideoBuffer:(CVPixelBufferRef)buffer;
- (void)publisher:(TVUIRLStreamPublisher *)publisher didReceiveAudioBuffer:(CMSampleBufferRef)buffer;
@end

@interface TVUIRLStreamPublisher : NSObject
@property (nonatomic, weak) id<TVUIRLStreamPublisherDelegate> delegate;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, assign) int32_t videoWidth;
@property (nonatomic, assign) int32_t videoHeight;
@property (nonatomic, assign) int32_t videoBitRate;
@property (nonatomic, assign) int32_t audioBitRate;
@property (nonatomic, assign) int32_t frameRate;
@property (nonatomic, assign) int32_t audioSampleRate;

- (void)startWithVideoSpec:(TVUIRLVideoSpec)videoSpec audioSpec:(TVUIRLAudioSpec)audioSpec;
- (void)stop;
- (void)appendVideoData:(NSData *)nalUnits
       presentationTime:(uint64_t)timestamp
               isKeyFrame:(BOOL)isKey;
- (void)appendAudioData:(NSData *)aacData
       presentationTime:(uint64_t)timestamp;
- (CVPixelBufferRef)previewBuffer;
@end
```

### 2.9 TVUIRLVideoConfigAvc.h/.m（已有，复用）

直接复用 `TVUIRLVideoConfigAvc`，无需新建。

### 2.10 TVUIRLVideoConfigHevc.h/.m（已有，复用）

直接复用 `TVUIRLVideoConfigHevc`，无需新建。

### 2.11 TVUIRLAudioConfig.h/.m（已有，复用）

直接复用 `TVUIRLAudioConfig`，无需新建。

### 2.12 TVUIRLMediaClock.h/.m（已有，复用）

直接复用 `TVUIRLMediaClock`，无需新建。

### 2.13 TVUIRLBandwidthMeter.h/.m（已有，复用）

直接复用 `TVUIRLBandwidthMeter`，无需新建。

### 2.14 TVUIRLDataReader.h/.m（已有，复用）

直接复用 `TVUIRLDataReader`，无需新建。

### 2.15 TVUIRLDataWriter.h/.m（已有，复用）

直接复用 `TVUIRLDataWriter`，无需新建。

### 2.16 TVUIRLAmfEncoder/Decoder/Value（已有，复用）

直接复用 `TVUIRLAmfEncoder` / `TVUIRLAmfDecoder` / `TVUIRLAmfValue`，无需新建。

---

## 三、需要迁移的 Swift 文件完整对照表

| 原 Swift 文件 | 迁移目标 | 说明 |
|---|---|---|
| `HaishinKit/Codec/VideoDecoder.swift` | `TVUIRLHardwareDecoder`（已有） | 视频硬解码 |
| `HaishinKit/Extension/CMVideoFormatDescription+Extension.swift` | 内联于 `TVUIRLVideoConfigAvc/Hevc` | 已复用 |
| `HaishinKit/Extension/Data+Extension.swift` | 内联于 `TVUIRLDataReader/Writer` | 已复用 |
| `HaishinKit/Extension/VTDecompressionSession+Extension.swift` | 内联于 `TVUIRLHardwareDecoder` | 已复用 |
| `HaishinKit/Flv/Flv.swift` | `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Media/Video/MetalPreviewView.swift` | `TVUIRLPreviewController` | 新建 |
| `HaishinKit/Media/Video/Shader.metal` | 保留 .metal 文件 + `TVUIRLShaderProgram` | Metal 着色器必须保留 |
| `HaishinKit/Media/Video/PreviewView.swift` | 内联于 `TVUIRLPreviewController` | 新建 |
| `HaishinKit/Media/TargetLatenciesSynchronizer.swift` | `TVUIRLMediaClock`（已有） | 音视频同步 |
| `HaishinKit/Mpeg/Avc/AvcNalUnit.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Mpeg/Avc/AvcNalUnitPps.swift` | 内联于 `TVUIRLVideoConfigAvc` | 已复用 |
| `HaishinKit/Mpeg/Avc/AvcNalUnitSei.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Mpeg/Avc/AvcNalUnitSps.swift` | 内联于 `TVUIRLVideoConfigAvc` | 已复用 |
| `HaishinKit/Mpeg/Avc/MpegTsVideoConfigAvc.swift` | `TVUIRLVideoConfigAvc`（已有） | 已复用 |
| `HaishinKit/Mpeg/Hevc/HevcNalUnit.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Mpeg/Hevc/HevcNalUnitPps.swift` | 内联于 `TVUIRLVideoConfigHevc` | 已复用 |
| `HaishinKit/Mpeg/Hevc/HevcNalUnitSei.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Mpeg/Hevc/HevcNalUnitSps.swift` | 内联于 `TVUIRLVideoConfigHevc` | 已复用 |
| `HaishinKit/Mpeg/Hevc/HevcNalUnitVps.swift` | 内联于 `TVUIRLVideoConfigHevc` | 已复用 |
| `HaishinKit/Mpeg/Hevc/MpegTsVideoConfigHevc.swift` | `TVUIRLVideoConfigHevc`（已有） | 已复用 |
| `HaishinKit/Mpeg/Adts.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Mpeg/AudioSpecificConfig.swift` | `TVUIRLAudioConfig`（已有） | 已复用 |
| `HaishinKit/Mpeg/MpegTsAudioConfig.swift` | `TVUIRLAudioConfig`（已有） | 已复用 |
| `HaishinKit/Mpeg/MpegTsVideoConfig.swift` | 内联于 `TVUIRLVideoConfigAvc/Hevc` | 已复用 |
| `HaishinKit/Mpeg/NalUnitReader.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Mpeg/NalUnitStream.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Mpeg/NalUnitWriter.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Rtmp/Amf/Amf.swift` | `TVUIRLAmfEncoder/Decoder/Value`（已有） | 已复用 |
| `HaishinKit/Rtmp/Message/RtmpAbortMessge.swift` | `TVUIRLProtocolMessage` 子类（已有） | 已复用 |
| `HaishinKit/Rtmp/Message/RtmpAcknowledgementMessage.swift` | `TVUIRLAckMessage`（已有） | 已复用 |
| `HaishinKit/Rtmp/Message/RtmpAggregateMessage.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Rtmp/Message/RtmpAudioMessage.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Rtmp/Message/RtmpCommandMessage.swift` | `TVUIRLCommandMessage`（已有） | 已复用 |
| `HaishinKit/Rtmp/Message/RtmpDataMessage.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Rtmp/Message/RtmpMessage.swift` | `TVUIRLProtocolMessage`（已有） | 已复用 |
| `HaishinKit/Rtmp/Message/RtmpSetChunkSizeMessage.swift` | `TVUIRLFlowControl`（已有） | 已复用 |
| `HaishinKit/Rtmp/Message/RtmpSetPeerBandwidthMessage.swift` | `TVUIRLBandwidthConfig`（已有） | 已复用 |
| `HaishinKit/Rtmp/Message/RtmpUserControlMessage.swift` | 内联于 `TVUIRLRtmpPublisher` | 新建 |
| `HaishinKit/Rtmp/Message/RtmpVideoMessage.swift` | 内联于 `TVUIRLFlvTagAssembler` | 新建 |
| `HaishinKit/Rtmp/Message/RtmpWindowAcknowledgementSizeMessage.swift` | `TVUIRLWindowAckMessage`（已有） | 已复用 |
| `HaishinKit/Rtmp/RtmpChunk.swift` | `TVUIRLMediaPacket`（已有） | 已复用 |
| `HaishinKit/Util/BitrateStats.swift` | `TVUIRLBandwidthMeter`（已有） | 已复用 |
| `HaishinKit/Util/ByteReader.swift` | `TVUIRLDataReader`（已有） | 已复用 |
| `HaishinKit/Util/ByteWriter.swift` | `TVUIRLDataWriter`（已有） | 已复用 |
| `RtmpServer/RtmpServer.swift` | `TVUIRLRtmpPublisher` | 新建 |
| `RtmpServer/RtmpServerChunkStream.swift` | 内联于 `TVUIRLRtmpPublisher` | 新建 |
| `RtmpServer/RtmpServerClient.swift` | 内联于 `TVUIRLRtmpPublisher` | 新建 |
| `RtmpServer/SettingsRtmpServer.swift` | `TVUIRLStreamConfig`（已有） | 已复用 |

---

## 四、文件清单

```
DJIStreamDemo/DJIStreamDemo/IngestObjc/
新建 ObjC 文件：
├── TVUIRLFlvTagAssembler.h/.m              # FLV Tag 组装
├── TVUIRLPreviewController.h/.m             # 预览控制器（替代 MetalPreviewView）
├── TVUIRLShaderProgram.h/.m                 # Shader 程序管理
├── TVUIRLTextureCache.h/.m                 # 纹理缓存
├── TVUIRLAudioEncoder.h/.m                 # PCM → AAC 编码
├── TVUIRLRtmpPublisher.h/.m                # RTMP 发布端
└── TVUIRLStreamPublisher.h/.m              # 统一发布接口

保留 Metal 文件（无法用 ObjC 替代）：
├── HaishinKit/Media/Video/Shader.metal     # 保留原文件

已有（RTMPServerObjc 复用，无需新建）：
├── TVUIRLDataReader.h/.m
├── TVUIRLDataWriter.h/.m
├── TVUIRLBandwidthMeter.h/.m
├── TVUIRLMediaClock.h/.m
├── TVUIRLVideoConfigAvc.h/.m
├── TVUIRLVideoConfigHevc.h/.m
├── TVUIRLAudioConfig.h/.m
├── TVUIRLAmfValue.h/.m
├── TVUIRLAmfEncoder.h/.m
├── TVUIRLAmfDecoder.h/.m
├── TVUIRLMediaPacket.h/.m
├── TVUIRLProtocolMessage.h/.m
├── TVUIRLCommandMessage.h/.m
├── TVUIRLAckMessage.h/.m
├── TVUIRLWindowAckMessage.h/.m
├── TVUIRLFlowControl.h/.m
├── TVUIRLBandwidthConfig.h/.m
└── TVUIRLHardwareDecoder.h/.m

已有 ObjC 文件：
├── RTMPIngestController.h/.m               # 已存在
```

---

## 五、实施顺序

### 第一阶段：核心发布（复用已有 + 新建发布端）
1. `TVUIRLFlvTagAssembler.h/.m` - FLV Tag 组装
2. `TVUIRLRtmpPublisher.h/.m` - RTMP 发布端
3. `TVUIRLStreamPublisher.h/.m` - 统一接口

### 第二阶段：音频编码
4. `TVUIRLAudioEncoder.h/.m` - PCM → AAC

### 第三阶段：预览系统（替代 Swift MetalPreviewView）
5. `TVUIRLTextureCache.h/.m` - 纹理缓存
6. `TVUIRLShaderProgram.h/.m` - Shader 管理
7. `TVUIRLPreviewController.h/.m` - 预览控制器

### 第四阶段：Swift 清理 + RTMPIngestController 更新
8. 删除所有 Ingest 中的 Swift 文件（除 Shader.metal）
9. 更新 `RTMPIngestController.h/.m` 绑定到新的 `TVUIRLStreamPublisher`

---

## 六、关键算法说明

### 6.1 FLV Video Tag H.264 NAL Unit 封装

Moblin/MPEG-TS 的 NAL Units 不含 StartCode，需要添加：
```objc
NSMutableData *flvData = [NSMutableData data];
for (NSData *nalUnit in nalUnits) {
    [flvData appendBytes:"\x00\x00\x00\x01" length:4];
    [flvData appendData:nalUnit];
}
```

### 6.2 HEVCDecoderConfigurationRecord 格式

FLV H.265 扩展头的序列数据（从 PacketType 后 4 字节 FourCC 之后开始）：
```
[vps_length(2)][vps_data...]
[sps_length(2)][sps_data...]
[pps_length(2)][pps_data...]
```
每个 length 为 2 字节大端表示。

### 6.3 RTMP 时间戳

Moblin RTMP 消息头的时间戳为 3 字节（24bit），毫秒级。
FLV Tag 的 timestamp 为 4 字节（24bit + 8bit extended），毫秒级。

### 6.4 Metal 渲染流程

```
CVPixelBuffer → CVMetalTextureCache → MTLTexture → TVUIRLTextureCache → TVUIRLShaderProgram → CAMetalLayer
```

---

## 七、与 RTMPServerObjc 的复用关系

| Ingest 类 | 复用自 RTMPServerObjc | 说明 |
|---|---|---|
| `TVUIRLFlvTagAssembler` | `TVUIRLVideoConfigAvc/Hevc` | 复用 AVCDecoderConfigurationRecord 构造逻辑 |
| `TVUIRLRtmpPublisher` | `TVUIRLStreamConnection` | 复用 RTMP 握手/命令/Chunk 逻辑（但方向相反） |
| `TVUIRLMediaClock` | 直接复用 | 音视频同步 |
| `TVUIRLBandwidthMeter` | 直接复用 | 码率统计 |
| `TVUIRLAmfEncoder` | 直接复用 | 发布端命令编码 |
| `TVUIRLTextureCache` | 新建 | 替代 Swift MetalPreviewView 纹理缓存 |
| `TVUIRLShaderProgram` | 新建 | 替代 Swift Shader 管理 |
| `TVUIRLPreviewController` | 新建 | 替代 Swift MetalPreviewView |

---

## 八、测试验证点

1. **RTMP 连接**：成功建立连接，握手流程正确
2. **发布命令**：connect → createStream → publish 命令序列正确
3. **视频序列头**：H.264/H.265 序列头能正确解析，播放器能开始解码
4. **视频数据帧**：NAL Units 正确封装为 FLV Video Tag，时间戳连续
5. **音频序列头**：AudioSpecificConfig 正确解析
6. **音频数据帧**：AAC 帧正确封装，时间戳与视频同步
7. **预览渲染**：Metal 预览正常显示，无内存泄漏
8. **码率统计**：发送码率与实际吻合
9. **Swift 清理**：工程中 Ingest 目录下无 .swift 文件（除 Shader.metal）

---

## 九、迁移完成记录

（待填充）
