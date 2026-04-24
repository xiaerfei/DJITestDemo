# Moblin 连接 DJI Osmo Action 5 Pro 技术调研报告

**调研人：** sharexia  
**日期：** 2026-04-23  
**目标：** 了解 Moblin iOS 应用连接 DJI Osmo Action 5 Pro 的技术实现方案，为 TVUAnywhere iOS 实现类似功能提供参考。

---

## 第一章：DJI Osmo Action 5 Pro 支持的连接方式

### 1.1 物理连接

**USB-C（UVC 模式 / Webcam 模式）**

Osmo Action 5 Pro 支持通过 USB-C 接口以 UVC（USB Video Class）协议工作，作为标准网络摄像头使用。
- 支持输出分辨率：最高 1080p@30fps，MJPEG 格式
- 支持 UAC（USB Audio Class）音频传输（固件更新后新增）
- **局限性**：UVC 在 Windows/macOS 上通用，但 **iOS/iPhone 不支持 USB 视频输入**，该模式无法在 iPhone 上直接使用

参考：[Using Osmo Series Product as a Webcam - DJI Support](https://support.dji.com/help/content?customId=en-us03400006962&spaceId=34&re=US&lang=en)

### 1.2 无线连接

**Wi-Fi（主要连接方式）**

Osmo Action 系列相机与移动设备的主要连接方式是 Wi-Fi：
- 支持频段：2.4 GHz、5.8 GHz、自动选择
- 相机可连接到手机热点（Personal Hotspot），也可以自身作为 AP
- Wi-Fi 用于数据传输（RTMP 推流）、DJI Mimo App 控制
- RTMP 推流时，相机推流到外部 RTMP 服务器地址（可以是本地 IP）

**蓝牙 BLE（辅助控制通道）**

官方文档明确说明：
> "Osmo Action 系列产品不能直接通过蓝牙与移动设备配对连接，否则 DJI Mimo App 可能无响应。"

但是，蓝牙的实际用途是：
- 当已经通过 Wi-Fi 连接时，蓝牙可以在不输入密码的情况下快速重连 Wi-Fi
- 第三方应用（如 Moblin）利用 BLE 作为**控制通道**，通过逆向工程的私有协议向相机发送 RTMP 推流配置指令

参考：[About Wireless Connection on Osmo Action Series Cameras](https://support.dji.com/help/content?customId=en-us03400006964&spaceId=34&re=US&lang=en&documentType=artical&paperDocType=paper)

### 1.3 连接方式总结

| 连接方式 | iOS 可用 | 用途 |
|----------|----------|------|
| USB-C (UVC) | 不支持 | PC/Mac 上当摄像头用 |
| Wi-Fi (相机推 RTMP) | 支持 | 视频数据传输 |
| BLE 蓝牙（私有协议）| 支持 | 控制相机（配置、启动推流） |
| DJI Mimo App | 支持 | 官方控制 App |

---

## 第二章：DJI 官方 SDK 对 Osmo Action 5 Pro 的支持情况

### 2.1 DJI Mobile SDK（MSDK）

DJI 提供面向无人机和部分手持设备的 [Mobile SDK](https://developer.dji.com/)，分为：
- **Mobile SDK v4**（旧版）：支持 Mavic 系列、Phantom 系列、Inspire 系列、Matrice 系列无人机，以及旧款 Osmo 稳定器（Osmo、Osmo Pro、Osmo Mobile 1/2）
- **Mobile SDK v5（MSDK 5.x）**（新版）：专注于新款无人机，截至 2025 年最新版本为 v5.17.0

**Osmo Action 系列不在 Mobile SDK 支持列表中。**

DJI SDK 论坛的官方回复明确表示：
> "OSMO 系列产品目前不支持 SDK 开发。"

相关证据：
- GitHub Issue（2019年提交）：[Add Osmo Pocket and Osmo Action support #415](https://github.com/dji-sdk/Mobile-SDK-Android/issues/415) — 大量用户请求但未被 DJI 官方实现
- DJI SDK 论坛帖子：[Does the API support the Osmo Action 4?](https://sdk-forum.dji.net/hc/en-us/community/posts/33842759473305-Does-the-API-support-the-Osmo-Action-4)

### 2.2 官方开放的替代方案

DJI 没有提供针对 Osmo Action 5 Pro 的 SDK，但有以下官方途径：
1. **DJI Mimo App**：官方配套 App，支持 RTMP 推流到自定义服务器
2. **DJI RSDK（R SDK）**：面向遥控器、配件（如 GPS 遥控器），基于 BLE 协议，有官方示例代码（ESP32-C6 示例），但不是针对 iOS App 的标准 SDK
3. **UVC/UAC**：通过 USB-C 以标准摄像头协议连接到 PC/Mac，不支持 iOS

### 2.3 结论

**DJI 官方 SDK 不支持 Osmo Action 5 Pro。** 想在 iOS App 中控制该相机，必须通过逆向工程实现私有 BLE 协议，或通过 Wi-Fi + RTMP 方式接收相机推流。

---

## 第三章：Moblin 是否开源及其代码仓库

### 3.1 开源信息

- **是的，Moblin 完全开源**
- **GitHub 仓库：** https://github.com/eerimoq/moblin
- **开源协议：** MIT License（完全开放，可商业使用）
- **主要语言：** Swift
- **作者：** eerimoq
- **App Store：** https://apps.apple.com/us/app/moblin/id6466745933
- **定位：** 面向户外（IRL）直播的免费 iOS 应用，主要支持 Twitch、YouTube、Kick、Facebook、OBS Studio 等平台

### 3.2 DJI 相关代码文件结构

```
Moblin/Integrations/Dji/
├── DjiMessage.swift                    # 消息协议编解码
└── DjiDevice/
    ├── DjiDevice.swift                 # BLE 连接主逻辑（CBCentralManager/CBPeripheralDelegate）
    ├── DjiDeviceMessage.swift          # 所有消息类型定义（配对、WiFi配置、启动推流等）
    ├── DjiDeviceModel.swift            # 设备型号识别（从 BLE manufacturer data 解析）
    └── DjiDeviceScanner.swift          # BLE 扫描器（发现 DJI 设备）
```

---

## 第四章：Moblin 连接 DJI Osmo Action 5 Pro 的技术实现

### 4.1 整体架构

Moblin 的方案是**双通道架构**：

```
iPhone (Moblin)
    │
    ├─── [BLE 蓝牙通道] ──→ DJI Osmo Action 5 Pro
    │         │
    │     发送控制指令：
    │     - 配对 (Pairing)
    │     - 配置 Wi-Fi 热点信息
    │     - 配置 RTMP 推流参数
    │     - 启动 / 停止推流
    │
    └─── [Wi-Fi 通道] ←── DJI Osmo Action 5 Pro
              │
          接收 RTMP 推流（H.264/H.265 视频流）
          Moblin 内嵌 RTMP 服务器接收数据
```

**关键洞察**：DJI Mimo App 不允许其他 App 同时持有 BLE 连接，所以使用前需要**彻底关闭 DJI Mimo App**，让 Moblin 获取 BLE 控制权。

### 4.2 BLE 连接实现细节

**扫描阶段（DjiDeviceScanner.swift）**

```swift
// 不使用 Service UUID 过滤，扫描所有 BLE 设备
central.scanForPeripherals(withServices: nil, options: nil)
```

通过解析 BLE 广播包中的 **Manufacturer Data** 来识别 DJI 设备：
- 字节 0-1：制造商 ID = `0xAA, 0x08`（DJI Technology Co. Ltd）或 `0xAA, 0xF7`（Xtra Ltd）
- 字节 2-3：设备型号标识

**设备型号识别（DjiDeviceModel.swift）**

| 设备型号 | Manufacturer Data 字节 2-3 |
|----------|--------------------------|
| Osmo Action 2 | `0x10, 0x00` |
| Osmo Action 3 | `0x12, 0x00` |
| Osmo Action 4 | `0x14, 0x00` |
| **Osmo Action 5 Pro** | **`0x15, 0x00`** |
| Osmo 360 | `0x17, 0x00` |
| Osmo Action 6 | `0x18, 0x00` |
| Osmo Pocket 3 | `0x20, 0x00` |

**连接与控制（DjiDevice.swift）**

```swift
// 使用 CoreBluetooth 标准 API
centralManager = CBCentralManager(delegate: self, queue: .main)

// 关键 GATT Characteristic UUID：
// FFF4 - 用于订阅通知和配对触发
private let fff4Id = CBUUID(string: "FFF4")
// FFF5 - 用于向相机写入命令
private let fff5Id = CBUUID(string: "FFF5")

// 发送命令（不等待响应）
cameraPeripheral?.writeValue(value, for: fff5Characteristic, type: .withoutResponse)
```

**连接状态机**：
```
discovering → connecting → pairing → preparingStream → configuring → startingStream → streaming
```

### 4.3 消息协议格式（DjiMessage.swift）

这是通过逆向工程发现的 **DJI 私有二进制协议**：

```
[0x55][Length][0x04][CRC8-Header][Target(2B LE)][ID(2B LE)][Type(3B LE)][Payload(变长)][CRC16]
```

字段说明：
- `0x55`：起始字节（固定）
- `Length`：消息总长度
- `0x04`：版本号（固定）
- `CRC8-Header`：头部校验（初始值 `0xEE`，多项式 `0x31`，反射输入/输出）
- `Target`：目标设备 ID（小端 16 位）
- `ID`：消息 Transaction ID（小端 16 位）
- `Type`：消息类型（小端 24 位）
- `Payload`：实际命令数据（变长）
- `CRC16`：数据完整性校验（初始值 `0x496C`，多项式 `0x1021`，反射操作）

**关键 Transaction ID**：

| 命令 | Transaction ID |
|------|---------------|
| 配对（Pair） | `0x8092` |
| 配置 Wi-Fi | `0x8C19` |
| 启动推流 | `0x8C2C` |
| 停止推流 | `0xEAC8` |

配对相关值：`pairTarget = 0x0702`，`pairType = 0x450740`

### 4.4 消息类型详解（DjiDeviceMessage.swift）

**WiFi 配置消息（DjiSetupWifiMessagePayload）**：
- 字段：`wifiSsid: String`、`wifiPassword: String`
- 编码方式：长度前缀 UTF-8 字符串

**启动推流消息（DjiStartStreamingMessagePayload）**：
```
- RTMP URL（推流目标地址）
- 分辨率：480p=0x47, 720p=0x04, 1080p=0x0A
- 帧率：25fps=0x02, 30fps=0x03
- 码率（kbps，16 位小端）
- 设备型号标识（OA5 Pro 有专属特殊处理分支）
```

**图像稳定模式（DjiConfigureMessagePayload）**：
- off / rockSteady / rockSteadyPlus / horizonBalancing / horizonSteady

**其他消息类型**：

| 消息类 | 作用 |
|--------|------|
| `DjiPairMessagePayload` | 配对（含 PIN 码） |
| `DjiPreparingToLivestreamMessagePayload` | 通知相机进入直播准备状态 |
| `DjiConfirmStartStreamingMessagePayload` | 确认推流启动 |
| `DjiStopStreamingMessagePayload` | 停止推流 |

### 4.5 完整工作流程

```
1. 用户打开 iPhone 个人热点
2. Moblin 启动内置 RTMP 服务器（监听本地端口，如 rtmp://192.168.x.x/live/stream）
3. Moblin 通过 CoreBluetooth 扫描所有 BLE 设备，解析 Manufacturer Data 识别 DJI 相机
4. 建立 BLE 连接，订阅 FFF4 Characteristic 通知，通过 FFF4 触发配对流程
5. 配对成功后，通过 FFF5 发送 DjiSetupWifiMessagePayload（写入热点 SSID + 密码）
6. 相机连接到 iPhone 热点（与 iPhone 处于同一局域网）
7. 通过 FFF5 发送 DjiStartStreamingMessagePayload（RTMP URL 指向 Moblin 本地服务器）
8. 相机开始推送 RTMP 流到 iPhone 本地地址（H.264/H.265 视频）
9. Moblin RTMP 服务器接收视频，将其作为独立视频源接入直播管道
```

### 4.6 参考开源项目（node-osmo）

TypeScript 版本的同等实现：[datagutt/node-osmo](https://github.com/datagutt/node-osmo)

该项目通过 noble（Node.js BLE 库）实现相同功能，致谢了 Spillmaker（最初逆向工程者）和 Moblin 项目（参考实现），证实两个项目使用的是同一套逆向出的私有协议。

---

## 第五章：结论与 TVUAnywhere iOS 实施建议

### 5.1 核心结论

| 问题 | 结论 |
|------|------|
| DJI 官方 SDK 是否支持 Osmo Action 5 Pro？ | **否**，DJI MSDK 不支持任何 Osmo Action 系列 |
| 是否有其他开放协议可连接（UVC/USB）？ | UVC 支持但 **iOS 不支持 USB 视频输入** |
| Moblin 是否开源？ | **是**，MIT 协议，GitHub 完全公开 |
| Moblin 使用什么技术？ | **逆向工程的私有 BLE 协议 + RTMP 接收** |
| 是否必须用 DJI SDK？ | **否**，通过 BLE 私有协议可完全绕过 DJI SDK |

### 5.2 TVUAnywhere iOS 实现方案

**推荐方案：参考 Moblin MIT 开源代码自行实现**

由于 Moblin 采用 MIT 协议开源，可以合法参考或直接移植其 DJI 集成代码。

**实施步骤：**

**Step 1：集成 BLE 控制模块**

参考 Moblin 的 `Moblin/Integrations/Dji/` 目录，将以下文件适配移植到 TVUIRLSDK：

```
DjiDevice.swift        → 负责 BLE 连接、配对、命令发送（使用系统 CoreBluetooth）
DjiDeviceMessage.swift → 所有命令消息的数据结构
DjiDeviceModel.swift   → 设备型号识别（含 OA5 Pro identifier 0x15,0x00）
DjiDeviceScanner.swift → BLE 扫描与设备发现
```

注意：需要将 Swift 代码适配到 TVUAnywhere 的 Objective-C 架构中，可通过 Swift 类暴露 ObjC 接口，或用 Bridging Header 混编。

**Step 2：实现本地 RTMP 服务器**

需要在 TVUAnywhere 内嵌轻量级 RTMP 服务器接收相机推流：
- 推荐使用 [HaishinKit.swift](https://github.com/shogo4405/HaishinKit.swift)（支持 RTMP 服务器模式）
- 或参考 Moblin 的 RTMP Ingest 实现（完整 Swift 代码开源）

**Step 3：iPhone 热点配合**

相机需要连接到 iPhone 热点以实现本地 RTMP 传输（相机和手机在同一局域网），RTMP 地址形如：
```
rtmp://172.20.10.1:1935/live/dji
```

**Step 4：视频源接入**

将本地 RTMP 接收到的视频流解码后，接入 TVUAnywhere 现有的视频源管道（`TVUSourceInputModule`）。

### 5.3 注意事项与风险

1. **协议稳定性**：这是逆向工程的私有协议，DJI 固件升级可能改变协议细节，需持续跟踪 Moblin 和 node-osmo 的更新
2. **DJI Mimo App 互斥**：BLE 控制权只能由一个 App 持有，使用时需确保 DJI Mimo 完全退出后蓝牙才能被 TVUAnywhere 接管
3. **延迟问题**：RTMP over Wi-Fi 存在固有延迟（通常 1~4 秒），通过降低 RTMP 缓冲区可改善
4. **热点依赖**：目前架构依赖 iPhone 热点作为中间 Wi-Fi 网络（蜂窝数据需开启），这是 DJI 相机连接 iPhone 的唯一实用方案
5. **iOS 后台 BLE 限制**：需在 `Info.plist` 中声明 `bluetooth-central` 后台模式（`UIBackgroundModes`），否则 App 进入后台后 BLE 连接会断开
6. **Info.plist 权限**：需增加 `NSBluetoothAlwaysUsageDescription` 权限说明

### 5.4 关键技术参数速查

| 参数 | 值 |
|------|----|
| DJI BLE 制造商 ID | `0xAA 0x08` |
| OA5 Pro 型号识别码 | `0x15 0x00` |
| 写入命令 Characteristic | `FFF5` |
| 接收通知 Characteristic | `FFF4` |
| 协议起始字节 | `0x55` |
| 头部 CRC8 初始值 | `0xEE` |
| 数据 CRC16 初始值 | `0x496C` |
| 启动推流 Transaction ID | `0x8C2C` |
| 停止推流 Transaction ID | `0xEAC8` |

---

## 参考资料

- [Moblin GitHub 仓库 (eerimoq/moblin)](https://github.com/eerimoq/moblin) — MIT 开源 iOS 直播 App
- [DjiDevice.swift 源码](https://github.com/eerimoq/moblin/blob/main/Moblin/Integrations/Dji/DjiDevice/DjiDevice.swift) — BLE 核心实现
- [DjiDeviceModel.swift 源码](https://github.com/eerimoq/moblin/blob/main/Moblin/Integrations/Dji/DjiDevice/DjiDeviceModel.swift) — 设备型号识别
- [DjiMessage.swift 源码](https://github.com/eerimoq/moblin/blob/main/Moblin/Integrations/Dji/DjiMessage.swift) — 私有协议格式
- [DjiDeviceMessage.swift 源码](https://github.com/eerimoq/moblin/blob/main/Moblin/Integrations/Dji/DjiDevice/DjiDeviceMessage.swift) — 消息类型定义
- [node-osmo (datagutt)](https://github.com/datagutt/node-osmo) — TypeScript 版同等实现，含相同 BLE UUID 和协议
- [DJI Developer Portal](https://developer.dji.com/) — DJI 官方开发者门户
- [DJI Mobile SDK iOS GitHub](https://github.com/dji-sdk/Mobile-SDK-iOS) — 官方 iOS SDK（不支持 Action 系列）
- [Osmo Action 系列无线连接官方说明](https://support.dji.com/help/content?customId=en-us03400006964&spaceId=34&re=US&lang=en&documentType=artical&paperDocType=paper)
- [Osmo Series Webcam 使用说明](https://support.dji.com/help/content?customId=en-us03400006962&spaceId=34&re=US&lang=en) — UVC 模式说明
- [Moblin 连接 DJI 相机教程 - AntiScuff](https://antiscuff.com/help/4-the-rest/how-to-connect-your-dji-camera-to-moblin/)
- [IRLhosting Moblin DJI RTMP 配置指南](https://irlhosting.com/whmcs/index.php?rp=/knowledgebase/7/How-to-Set-Up-RTMP-Streaming-in-Moblin-with-DJI-Pocket-3orDJI-Action-4or5.html)
- [DJI SDK 论坛：Osmo Action 4 API 支持请求](https://sdk-forum.dji.net/hc/en-us/community/posts/33842759473305-Does-the-API-support-the-Osmo-Action-4)
- [DJI Wi-Fi 协议逆向工程论文（2021）](https://www.digidow.eu/publications/2021-christof-masterthesis/Christof_2021_MasterThesis_DJIProtocolReverseEngineering.pdf)

---

# 第二部分：Demo 工程实操手册

> 本部分记录 DJIStreamDemo 工程从零搭建到真机跑通的全过程细节。
> 工程路径：`/Users/tvum4pro/Desktop/Demo/DJIStreamDemo`
> 目标：按"Scan → 选相机 → 填 Wi-Fi + RTMP URL → Start → 本地预览画面"的流程打通。

---

## 第六章：整体架构与数据流

### 6.1 两条并行通道

```
┌─────────────────────────────────────────────────────────────────┐
│                         iPhone (本 Demo)                         │
│                                                                 │
│  ┌───────────────────┐          ┌──────────────────────────┐    │
│  │  DJI BLE 控制通道 │          │  RTMP Ingest 视频通道    │    │
│  │  (CoreBluetooth)  │          │  (Network.framework)     │    │
│  │                   │          │                          │    │
│  │  DJIStreamCtrl    │          │  RTMPIngestController    │    │
│  │    │              │          │    │                     │    │
│  │    ├─ Scanner     │          │    ├─ RtmpServer         │    │
│  │    └─ DjiDevice   │          │    │   └─ NWListener      │    │
│  │        (GATT)     │          │    │      :1935          │    │
│  │                   │          │    ├─ RtmpServerClient   │    │
│  │                   │          │    │   (per TCP conn)    │    │
│  │                   │          │    └─ PreviewView        │    │
│  └─────────┬─────────┘          └────────────┬─────────────┘    │
│            │                                 │                  │
└────────────┼─────────────────────────────────┼──────────────────┘
             │                                 │
             │ BLE FFF5 (write)                │ RTMP over TCP
             │ BLE FFF4 (notify)               │ (入站)
             ▼                                 ▲
   ┌──────────────────────────────────────────────────┐
   │            DJI Osmo Action 5 Pro                  │
   │                                                   │
   │  1. 收到 BLE 指令 → 连到指定 Wi-Fi                │
   │  2. 推 RTMP 到指定 URL（H.265 + AAC）             │
   └──────────────────────────────────────────────────┘
```

**关键点**：两条通道同时使用，BLE 只用来"下命令"，真正的视频数据完全走 Wi-Fi + RTMP。

### 6.2 端到端时序

用户点 Start 后，按时间顺序发生的事情：

```
时刻    动作                                           组件
─────────────────────────────────────────────────────────────────────
T+0    ViewController.onStartTap                      ViewController.m
T+0    解析 RTMP URL → 拿到 port + streamKey           ViewController.m
T+0    RTMPIngestController.start(port, streamKey)    Ingest/...
T+0    ├─ 创建 SettingsRtmpServer                     RtmpServer.swift
T+0    └─ NWListener.start(:1935)                     RtmpServer.swift
T+0    DJIStreamController.startLiveStream(...)       DJI/...
T+0    └─ DjiDevice.startLiveStream(...)              DjiDevice.swift
T+0    └─ CBCentralManager.scanForPeripherals         (BLE 扫描目标机)
T+0.5  BLE 发现目标相机 (按 deviceId 匹配)             DjiDevice.swift
T+0.5  CBCentralManager.connect(peripheral)           (建立 BLE 连接)
T+1    GATT 服务/特征发现完成                          DjiDevice.swift
T+1    订阅 FFF4 notify                               DjiDevice.swift
T+1    写 FFF5: 配对消息 (transactionId=0x8092)       DjiDevice.swift
T+1    状态：checkingIfPaired                         DjiDevice.swift
T+2    收到配对响应 → 状态：pairing                    DjiDevice.swift
T+2    写 FFF5: stopStream (清理残留)                 DjiDevice.swift
T+2    状态：cleaningUp                               DjiDevice.swift
T+3    写 FFF5: preparingToLivestream (0x8C12)       DjiDevice.swift
T+3    状态：preparingStream                          DjiDevice.swift
T+3    写 FFF5: setupWifi (SSID + password)          DjiDevice.swift
T+3    状态：settingUpWifi                            DjiDevice.swift
T+3~8  相机断开当前 AP 并连到指定 Wi-Fi               (相机内部)
T+8    收到 setupWifi 成功响应 (payload = 0x00 0x00)   DjiDevice.swift
T+8    写 FFF5: configure (image stabilization)       DjiDevice.swift
T+8    状态：configuring                              DjiDevice.swift
T+9    写 FFF5: startStreaming (RTMP URL + 分辨率)    DjiDevice.swift
T+9    [OA5 Pro 专属] 写 FFF5: confirmStartStream    DjiDevice.swift
T+9    状态：startingStream                           DjiDevice.swift
T+10   状态：streaming                                DjiDevice.swift
───────────────────────────────────────────────────────────────────
T+10~12 相机向 rtmp://iPhone-IP:1935/live/<key> 发 TCP 连接
T+12   NWListener 触发 newConnection handler          RtmpServer.swift
T+12   创建 RtmpServerClient                          RtmpServerClient.swift
T+12   收到 C0+C1 → 回 S0+S1+S2                      RtmpServerClient.swift
T+12   收到 C2 → 握手完成                             RtmpServerClient.swift
T+13   AMF 命令：connect ("live" app)                  RtmpServerChunkStream
T+13   回 _result + WindowAck + SetPeerBandwidth     RtmpServerClient
T+13   AMF 命令：createStream → 回 streamId          RtmpServerChunkStream
T+13   AMF 命令：publish <streamKey>                  RtmpServerChunkStream
T+13   匹配 settings.streams 里的 streamKey           RtmpServerChunkStream
T+13   rtmpServerOnPublishStart(streamKey) 触发       RTMPIngestCtrl
T+13   UI status: "publishing (dji)"                  ViewController.m
───────────────────────────────────────────────────────────────────
T+13+  相机发 AMF Data 消息：@setDataFrame (metadata)
T+13+  相机发 Video 消息：FLV tag (avcC/hvcC 配置包)
T+13+  VideoDecoder 创建 VTDecompressionSession       VideoDecoder.swift
T+14   相机发 Video 消息：第一个 IDR 关键帧
T+14   VT 解码成 CVPixelBuffer                        VideoDecoder.swift
T+14   CMSampleBuffer.create(...) 打包                ByteIO.swift
T+14   RtmpServer → rtmpServerOnVideoBuffer(...)     RtmpServerChunkStream
T+14   RTMPIngestController.previewView.enqueue       RTMPIngestCtrl
T+14   AVSampleBufferDisplayLayer 渲染 → 首帧出现     PreviewView.swift
───────────────────────────────────────────────────────────────────
```

**正常情况总耗时：从点 Start 到首帧上屏大约 10~15 秒**（绝大部分时间花在相机切 Wi-Fi 网络）。

### 6.3 工程目录结构

```
DJIStreamDemo/
├── DJIStreamDemo/                    ← 主 target 源码
│   ├── AppDelegate.{h,m}             ← 模板代码
│   ├── SceneDelegate.{h,m}           ← 模板代码
│   ├── ViewController.{h,m}          ← 唯一 UI，ObjC 驱动
│   ├── Info.plist                    ← 权限声明
│   │
│   ├── DJI/                          ← BLE 控制通道（从 Moblin 移植）
│   │   ├── DjiMessage.swift          ← 私有协议帧编解码 (CRC8 + CRC16)
│   │   ├── DjiDevice.swift           ← BLE 连接 + 状态机核心
│   │   ├── DjiDeviceMessage.swift    ← 各命令 payload（配对/WiFi/推流）
│   │   ├── DjiDeviceModel.swift      ← manufacturerData 识别型号
│   │   ├── DjiDeviceScanner.swift    ← 扫描所有 DJI 设备
│   │   ├── DJIStreamController.swift ← ★ @objc facade（ObjC 调这个）
│   │   └── Support/
│   │       ├── ByteIO.swift          ← ★ Moblin 兼容层 (all extensions)
│   │       ├── DjiCrc.swift          ← CRC8(0x31) / CRC16(0x1021)
│   │       ├── DjiLogger.swift       ← 全局 `logger`（print 输出）
│   │       ├── DjiSettings.swift     ← Model/Resolution/ImageStab 枚举
│   │       └── SimpleTimer.swift     ← DispatchSourceTimer 封装
│   │
│   └── Ingest/                       ← RTMP 接收通道（从 Moblin 移植）
│       ├── RTMPIngestController.swift← ★ @objc facade（ObjC 调这个）
│       ├── RtmpServer/
│       │   ├── RtmpServer.swift      ← NWListener 主循环
│       │   ├── RtmpServerClient.swift← 每个 TCP 连接一个实例
│       │   ├── RtmpServerChunkStream ← 每个 Stream ID 一个实例
│       │   └── SettingsRtmpServer    ← 我写的精简配置 (stub)
│       └── HaishinKit/               ← 移植的 HaishinKit 子集
│           ├── Rtmp/                 ← RTMP 协议 (Amf, Message, Chunk)
│           ├── Flv/                  ← FLV 标签枚举定义
│           ├── Mpeg/                 ← NALU 解析、配置包解析
│           │   ├── Avc/              ← H.264 NALU (SPS/PPS/SEI)
│           │   ├── Hevc/             ← H.265 NALU (VPS/SPS/PPS/SEI)
│           │   ├── NalUnit{Reader,Writer,Stream}.swift
│           │   ├── MpegTsVideoConfig{,Avc,Hevc}.swift
│           │   ├── MpegTsAudioConfig.swift
│           │   ├── AudioSpecificConfig.swift
│           │   └── Adts.swift
│           ├── Codec/
│           │   └── VideoDecoder.swift ← VTDecompressionSession
│           ├── Util/
│           │   ├── ByteReader.swift  ← 字节流解析 (Moblin 完整版)
│           │   ├── ByteWriter.swift  ← 字节流构建
│           │   └── BitrateStats.swift
│           ├── Extension/
│           │   ├── Data+Extension.swift
│           │   ├── CMVideoFormatDescription+Extension.swift
│           │   └── VTDecompressionSession+Extension.swift
│           └── Media/
│               ├── TargetLatenciesSynchronizer.swift
│               └── Video/
│                   └── PreviewView.swift ← AVSampleBufferDisplayLayer 视图
│
├── DJIStreamDemo.xcodeproj/
│   └── project.pbxproj               ← 文件注册 + 权限 key
└── DJIStreamDemoTests/, DJIStreamDemoUITests/
```

**★ 标记的是"你自己写的 Demo 接入代码"，其余都是 Moblin 原版或兼容层**，出问题时优先排查标星的。

---

## 第七章：BLE 控制通道详细工作机制

### 7.1 CoreBluetooth 交互链

所有 BLE 代码都在 `DJI/DjiDevice.swift`，使用 `DjiDeviceState` 枚举追踪当前走到哪一步：

```
CBCentralManager.scanForPeripherals(withServices: nil)  ← 不过滤 service
  → didDiscover → 比对 peripheral.identifier
CBCentralManager.connect(peripheral)
  → didConnect → peripheral.discoverServices(nil)
  → didDiscoverCharacteristics → 记录 FFF4(notify) 和 FFF5(write)
  → setNotifyValue(true, for: FFF4)
  → didUpdateNotificationStateFor → 发配对请求
peripheral.writeValue(encodedMsg, for: FFF5, type: .withoutResponse)
peripheral.didUpdateValueFor(FFF4) → 解析响应 → 推进状态机
```

### 7.2 设备识别

扫描阶段不过滤 Service UUID，通过 Manufacturer Data 识别：

```
广告包 Manufacturer Data [0..3]:
  [0:2] = 公司 ID
    AA 08 → DJI Technology Co. Ltd
    AA F7 → Xtra Ltd
  [2:4] = 型号标识
    15 00 → Osmo Action 5 Pro   ← 我们关心的
    14 00 → Osmo Action 4
    18 00 → Osmo Action 6
    12 00 → Osmo Action 3
    10 00 → Osmo Action 2
    17 00 → Osmo 360
    20 00 → Osmo Pocket 3
```

相关代码：`DJI/DjiDeviceModel.swift`、`DJI/DjiDeviceScanner.swift`。

### 7.3 私有协议帧格式

```
┌──────┬──────┬──────┬──────┬─────────┬─────────┬────────────┬──────────┬────────┐
│ 0x55 │ Len  │ 0x04 │CRC8  │Target   │  ID     │   Type     │  Payload │ CRC16  │
│ 1B   │ 1B   │ 1B   │ 1B   │ 2B LE   │ 2B LE   │  3B LE     │  变长    │ 2B LE  │
└──────┴──────┴──────┴──────┴─────────┴─────────┴────────────┴──────────┴────────┘
```

- 起始 `0x55`，版本 `0x04` 固定
- CRC8 算前 3 字节，`init=0xEE, poly=0x31, refIn/Out=true`
- CRC16 算到 Payload 结束，`init=0x496C, poly=0x1021, refIn/Out=true`
- CRC 实现在 `DJI/Support/DjiCrc.swift`（手写替换了 Moblin 的 CrcSwift SPM 依赖）

### 7.4 关键命令 Transaction ID

| 命令 | Target | ID | Type | 触发状态 |
|------|-------|----|----|---------|
| Pair | 0x0702 | 0x8092 | 0x450740 | checkingIfPaired |
| StopStream | 0x0802 | 0xEAC8 | 0x8E0240 | stoppingStream |
| PreparingLive | 0x0802 | 0x8C12 | 0xE10240 | preparingStream |
| SetupWifi | 0x0702 | 0x8C19 | 0x470740 | settingUpWifi |
| StartStream | 0x0802 | 0x8C2C | 0x780840 | startingStream |
| Configure | 0x0102 | 0x8C2D | 0x8E0240 | configuring |

常量集中在 `DJI/DjiDevice.swift` 开头。

### 7.5 OA5 Pro 的协议变种

OA5 Pro / Action 6 / Osmo 360（`hasNewProtocol() == true`）相对旧协议有两处差异：

1. **startStream payload 第 1 字节**：新协议 `0x2A`，旧协议 `0x2E`（`DjiStartStreamingMessagePayload.encode()` 里按 `oa5` 参数切换）
2. **多发一条确认启动包**：格式就是 stopStream，但 payload 末字节 `0x02` → `0x01`（`DjiConfirmStartStreamingMessagePayload`；`DjiDevice.sendStartStreaming()` 中 `if model.hasNewProtocol()`）

**缺这步 OA5 Pro 会卡在"已接受 startStream 但不真推流"**。

---

## 第八章：RTMP Ingest 详细工作机制

### 8.1 三层对象模型

```
RtmpServer (单例)
  持有 NWListener :1935，每个 TCP 连接起一个 RtmpServerClient
  │
  └─> RtmpServerClient (1 个/TCP 连接)
        处理 RTMP 握手、chunk basic/message header 解析
        按 chunk stream ID 分发到 RtmpServerChunkStream
        │
        └─> RtmpServerChunkStream (N 个/client, 按 csid 索引)
              累积 messageBody，按 messageTypeId 分发：
                0x08 audio    → FLV audio tag
                0x09 video    → FLV video tag → VideoDecoder
                0x12/0x11 AMF → 命令 (connect/createStream/publish)
                0x01/0x05/0x06 → 控制消息
```

### 8.2 RTMP 握手

在 `RtmpServerClient.swift`：

```
相机 → C0 (1B 版本 0x03)
相机 → C1 (1536B time+zero+random)
我  → S0 (1B 0x03)
我  → S1 (1536B time=0+zero+random)
我  → S2 (1536B 相机的 C1 回传)
相机 → C2 (1536B 我的 S1 回传)
握手完成 → 进入 Chunk 解析
```

卡在这步 → 在 `RtmpServerClient.start()` / `handleReceive` 打断点。

### 8.3 Chunk 解析状态机

`RtmpServerChunkStream` 用枚举 `ChunkState` 追踪：

```
basicHeaderFirstByte   → 解 csid 和 type (0/1/2/3)
messageHeaderType0(11) → Type 0: 完整头+绝对时间戳
messageHeaderType1(7)  → Type 1: 省略 messageStreamId
messageHeaderType2(3)  → Type 2: 只有时间戳增量
(Type 3: 无消息头，直接数据)
extendedTimestamp(4)   → 可选
data (min(chunkSize, remainingLen))
→ 累积完一条 message 就 handleBody
```

### 8.4 AMF 命令分发

握手后相机发的 AMF 命令（`RtmpServerChunkStream.handleAmfCommand`）：

```
1. connect (tcUrl, app="live")
   → _result + WindowAckSize(2500000) + SetPeerBandwidth + chunkSize(65536)
2. releaseStream / FCPublish → 忽略（部分客户端会发）
3. createStream → _result(streamId)
4. publish (streamKey, "live")
   → 查 settings.streams 匹配 streamKey
   → 匹配：rtmpServerOnPublishStart 回调
   → 不匹配：踢连接 ("Stream key ... not configured")
```

streamKey 不一致的日志关键字：`Stream key ... not configured`。

### 8.5 从 RTMP video msg 到 NALU

`RtmpServerChunkStream.handleVideo(message:)`:

```
第一字节 control = frameType(高4位) | codecId(低4位)
  frameType: 1=keyframe, 2=inter
  codecId: 7=AVC(H.264), 12=HEVC(H.265)

如果 control 高位是 extendedVideoHeader(0x80)：
  Enhanced RTMP 格式：第一字节=packetType|frameType
  后续 4 字节=codec fourCC ("hvc1" 等)

第二字节 packetType:
  0 = sequence header (avcC/hvcC 配置)
  1 = NALU 数据 (AVCC: 4B长度前缀 + NALU)
  2 = 结束

序列头路径：
  → MpegTsVideoConfigAvc/Hevc.make() 提取 SPS/PPS/VPS
  → CMVideoFormatDescription 创建
  → VideoDecoder.formatDescription = 该描述 → 创建 VTDecompressionSession

NALU 数据路径：
  → Data.makeBlockBuffer() → CMBlockBuffer
  → CMSampleBufferCreate 带时间戳
  → VideoDecoder.decodeSampleBuffer
  → VTDecompressionSessionDecodeFrameWithOutputHandler
  → CVImageBuffer → CMSampleBuffer.create → rtmpServerOnVideoBuffer 回调
```

### 8.6 时间戳处理

RTMP 时间戳是 uint32 毫秒（相对 publish 开始）：

```swift
videoTimestamp = mediaTimestamp / 1000.0    // 毫秒 → 秒
presentationTimeStamp = CMTime(seconds: videoTimestamp, preferredTimescale: 1000)
```

画面时快时慢 → 断点打在 `processTimestamp` 相关路径。

---

## 第九章：视频解码与显示管线

### 9.1 VideoDecoder

`Ingest/HaishinKit/Codec/VideoDecoder.swift`：

```swift
class VideoDecoder {
    var formatDescription: CMVideoFormatDescription?
    weak var delegate: VideoDecoderDelegate?

    func decodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // 1. 无 session 时用 formatDescription 创建 VTDecompressionSession
        // 2. 输出像素格式 = 420YpCbCr8BiPlanarFullRange (NV12)
        // 3. VTDecompressionSessionDecodeFrameWithOutputHandler（异步回调）
        // 4. 回调：CMSampleBuffer.create(...) → delegate 回调
    }
}
```

RtmpServerChunkStream 实现 `VideoDecoderDelegate`，在回调里调 `server.delegate.rtmpServerOnVideoBuffer(...)`。

### 9.2 RTMPIngestController

`Ingest/RTMPIngestController.swift` — 我写的 @objc facade，三件事：

1. 实例化 RtmpServer 并做它的 delegate
2. 持有 PreviewView，把解码好的 CMSampleBuffer 转发
3. 暴露 ObjC 可调用接口

### 9.3 PreviewView

`Ingest/HaishinKit/Media/Video/PreviewView.swift`：

```swift
class PreviewView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    func enqueue(_ sampleBuffer: CMSampleBuffer?, isFirstAfterAttach: Bool) {
        DispatchQueue.main.async {
            if self.layer.status == .failed { self.layer.flush() }
            if isFirstAfterAttach {
                self.layer.flushAndRemoveImage()  // 清旧画面
            } else {
                self.layer.enqueue(sampleBuffer)   // 真正渲染
            }
        }
    }
}
```

`AVSampleBufferDisplayLayer` 自己管时序。**layer.status 变 .failed 画面就停**，代码里做了 flush 自愈。

### 9.4 ObjC ↔ Swift 桥接

主工程是 ObjC，Swift 文件通过派生目录的自动生成头暴露：

```
DerivedData/.../DJIStreamDemo-Swift.h
```

`#import "DJIStreamDemo-Swift.h"` 就能用 @objc 标记过的 Swift 类：
- `DJIStreamController`、`DJIStreamControllerDelegate`、`DJIDiscoveredPeripheral`
- `DJIStreamState`、`DJIStreamResolution`、`DJIStreamImageStabilization`（@objc enum）
- `RTMPIngestController`、`RTMPIngestControllerDelegate`

未标 @objc 的类（`RtmpServer`, `DjiDevice`, `PreviewView`）ObjC 看不到，只能通过 facade 间接使用。

---

## 第十章：关键代码路径速查表

| 症状 | 第一处看 | 第二处看 |
|------|---------|----------|
| 扫不到相机 | `DjiDeviceScanner.swift:didDiscover` — manufacturerData 前缀是否 AA 08/AA F7 | BLE 权限、相机是否被 DJI Mimo 占用 |
| 卡 connecting | `DjiDevice.swift:didUpdateNotificationStateFor` — 是否订阅到 FFF4 | GATT 服务发现日志 |
| 卡 pairing | `DjiDevice.swift:processCheckingIfPaired` — 响应 payload | 相机 PIN 是否 "mbln"（硬编码） |
| 卡 settingUpWifi | `DjiDevice.swift:processSettingUpWifi` — payload 是否 `00 00` | Wi-Fi 密码对否，相机能连该 Wi-Fi 否 |
| streaming 但无画面 | `RtmpServer.swift:handleNewListenerConnection` — TCP 连接是否进来 | AP client isolation 是否开了 |
| publish 被拒 | `RtmpServerChunkStream.swift` 搜 `not configured` | streamKey 不一致 |
| 画面黑屏 | `VideoDecoder.swift:makeSession` — VT session 创建日志 | HEVC 解码失败、格式描述出错 |
| 画面花屏 | `RtmpServerChunkStream.swift:handleVideo` — 关键帧标记 | AVCC 长度前缀解析、SPS/PPS 顺序 |
| 延迟大 | PreviewView + AVSampleBufferDisplayLayer | 调 `setAttachmentDisplayImmediately` |
| 时快时慢 | `RtmpServerChunkStream.swift` — `mediaTimestamp` 相关 | Type 1/2/3 header 时间增量 |

---

## 第十一章：故障排查手册

### 11.1 按症状

**A. Scan 后列表空**
- 蓝牙权限开了吗？相机开机了吗？
- **DJI Mimo App 在运行吗？**（必须完全退出）
- 日志搜 `dji-scanner: Manufacturer data` — 如果没你的型号，可能型号 ID 改了

**B. 卡 connecting / pairing**
- 相机之前被其他 App 配对过？长按开关键 reset
- 日志搜 `dji-device: State change` — 最后停在哪？
- `connecting`：FFF4 没订阅成功
- `checkingIfPaired`/`pairing`：相机没回配对响应

**C. 卡 settingUpWifi 或 wifiSetupFailed**
- SSID/密码对吗？手动用 iPhone 连验证
- 相机支持频段？OA5 Pro 支持 2.4G/5G，不支持 6GHz Wi-Fi 6E
- 相机卡旧配置？重启相机

**D. streaming 达成但 preview 黑屏**
1. 相机根本没推上来
   - 日志搜 `rtmp-server: Client TCP connected` 没有？
   - 不同 LAN / AP 隔离客户端
   - 端口 LISTEN 验证：`netstat -an | grep 1935`
2. TCP 上来但 publish 被拒
   - 日志搜 `Stream key ... not configured`
   - RTMP URL 末段 vs streamKey 不一致
3. publish 成功但解码失败
   - 日志搜 `video-decoder: Format description missing`
   - HEVC hvcC 出错，排查 `MpegTsVideoConfigHevc.make()`

**E. 退后台回来画面停**
AVSampleBufferDisplayLayer 进后台停。目前代码未处理后台恢复，需要：
```swift
sceneWillEnterForeground { previewView.layer.flushAndRemoveImage() }
```

### 11.2 快速重置

1. 点 Stop 按钮
2. 相机长按电源键重启
3. 确认 DJI Mimo 彻底退出
4. Demo 重新 Scan

---

## 第十二章：日志关键字速查

**BLE 通道**
- `dji-scanner:` — 扫描发现
- `dji-device: Start live stream` — startLiveStream 入口
- `dji-device: State change` — 状态机每次转移
- `dji-device: Send target:` — 每条 BLE 命令
- `dji-device: Discarding corrupt message` — CRC 失败
- `dji-device: Received message in unexpected state` — 状态机收到意外消息

**RTMP 通道**
- `rtmp-server: State change to` — NWListener 状态
- `rtmp-server: Listening on port` — Server 就绪
- `rtmp-server: Client TCP connected` — 相机接入
- `rtmp: Command message` — AMF 命令解析出错
- `video-decoder:` — 解码相关

**App 层**
- `rtmp-ingest: Listening on` — RTMPIngestController 启动
- `rtmp-ingest: Publish started for` — publish 成功

---

## 第十三章：构建配置速查

- **部署目标**：iOS 16.0（`ContinuousClock.now` 要求）
- **Info.plist 关键键**（通过 `INFOPLIST_KEY_*` 注入）：
  - `NSBluetoothAlwaysUsageDescription`
  - `UIBackgroundModes = bluetooth-central`
- **Swift 设置**：`SWIFT_VERSION = 5.0`；Debug `-Onone`，Release `-O`
- **桥头文件**：自动生成的 `DJIStreamDemo-Swift.h` 足够，无需手写
- **零 SPM 依赖**：CrcSwift 被手写 CRC 替代；Collections/MetalPetal 没搬（它们只是推流侧用）
- **代码量**：65 个源文件，约 5700 行；其中自己写的胶水约 800 行，Moblin 移植约 4800 行

---

## 第十四章：未来扩展点

1. **音频播放**：`rtmpServerOnAudioBuffer` 当前空实现
2. **录制到文件**：`rtmpServerOnVideoBuffer` 分支加 AVAssetWriter
3. **低延迟**：每个 CMSampleBuffer 调 `setAttachmentDisplayImmediately()`
4. **接入 TVUAnywhere**：CMSampleBuffer 直接走 `TVUSourceInputModule`，不要 preview
5. **多相机并发**：`SettingsRtmpServer.streams` 本就是数组
6. **Info.plist 本地化**：上架要补中文
7. **后台推流**：RTMP server 退后台会被挂起，要 audio 后台模式或 BGTask

---

## 第十五章：各型号支持的分辨率 / 码率能力矩阵

### 15.1 核心前提：协议是逆向出来的，**没有能力查询接口**

DJI 的 BLE 私有协议 **没有任何 "capability query" 消息**。相机不会主动告诉你"我支持哪些分辨率/帧率/码率组合"，你只能：

1. 发送你想要的参数
2. 看相机是接受（开始推流）、还是拒绝（推流不启动 / 推出来的实际参数被硬压低）

这意味着**支持范围的唯一权威来源**是：
- DJI Mimo App（官方配套 App 里展示什么选项，相机就接受什么）
- DJI 相机规格页面（产品官网的 spec sheet，live streaming 部分）
- 实机测试（把 Demo 的参数改了，看相机反应）

Moblin / 本 Demo 里的那组参数（480/720/1080p × 2~20 Mbps × 25/30fps）是**所有型号通用的"安全集"**，是 Moblin 作者在 OA3/4/5 Pro / Pocket 3 上测试验证过的交集。

### 15.2 Moblin 源码里"所有型号一视同仁"的参数

翻 `DjiDeviceMessage.swift` 的 `DjiStartStreamingMessagePayload.encode()`：

```swift
switch resolution {
case .r480p:  resolutionByte = 0x47
case .r720p:  resolutionByte = 0x04
case .r1080p: resolutionByte = 0x0A
}
switch fps {
case 25: fpsByte = 2
case 30: fpsByte = 3
default: fpsByte = 0
}
```

**不管哪个型号，发出去的协议字节都从这 3×2=6 种组合里选**。Moblin 从未测试过 1440p/4K/60fps 的字节编码，所以即使相机本体支持 4K 录制，Demo 目前也无法让它推 4K RTMP（需要逆向新字节）。

Moblin `SettingsDjiDevice.swift` 里码率预设数组：
```swift
var djiDeviceBitrates: [UInt32] = [
    20_000_000, 16_000_000, 12_000_000, 10_000_000,
    8_000_000, 6_000_000, 4_000_000, 2_000_000,
]
```

码率字段在协议里是 `UInt16 kbps`，理论能塞 2000~65535 kbps（即 2~65 Mbps），Moblin 预设只覆盖 2~20 Mbps。

### 15.3 唯一的型号差异：协议变种

`SettingsDjiDeviceModel.swift` 里有两个方法按型号切换：

```swift
func hasNewProtocol() -> Bool {
    case .osmoAction5Pro, .osmoAction6, .osmo360: return true
    default:                                       return false
}

func hasImageStabilizatin() -> Bool {
    case .osmoAction4, .osmoAction5Pro, .osmoAction6, .osmo360: return true
    default:                                                    return false
}
```

| 型号 | hasNewProtocol | hasImageStabilization |
|------|---------------|----------------------|
| Osmo Action 2 | ❌ | ❌ |
| Osmo Action 3 | ❌ | ❌ |
| Osmo Action 4 | ❌ | ✅ |
| Osmo Action 5 Pro | ✅ | ✅ |
| Osmo Action 6 | ✅ | ✅ |
| Osmo Pocket 3 | ❌ | ❌ |
| Osmo 360 | ✅ | ✅ |

这两个标记影响的是"怎么发命令"，**不影响支持的分辨率/码率**（那几个值所有型号都走一样的编码）。

### 15.4 DJI 官方规格里的 Live Streaming 上限（查产品页）

从 DJI 产品页 "Specifications → Live Streaming / Webcast" 段落整理（这些是官方公开信息）：

| 型号 | 官网声明的 Live Streaming 最高规格 |
|------|---------------------------------|
| Osmo Action 3 | 1080p @ 30fps |
| Osmo Action 4 | 1080p @ 30fps |
| Osmo Action 5 Pro | 1080p @ 30fps |
| Osmo Action 6 | 1080p @ 30fps（待官网确认） |
| Osmo Pocket 3 | 1080p @ 30fps |
| Osmo 360 | 1080p @ 30fps（待官网确认） |

**共同规律**：不管相机本体能拍 4K/60fps 甚至 8K，RTMP 直播输出**DJI 全系都锁在 1080p/30fps 以内**。这也是为什么 Moblin 只支持到这里。

> 码率官网基本不公布，DJI Mimo 里的选项更有参考价值（见下一节）。

### 15.5 用 DJI Mimo App 反查可选参数（推荐方法）

**这是最靠谱的办法**，5 分钟出结果：

1. 相机开机，**关闭** Moblin / 本 Demo（不要抢 BLE）
2. iPhone 打开 DJI Mimo，连上相机
3. 进入"直播"（Livestream）功能：
   - 选 "RTMP" → "自定义 RTMP"
4. 进入直播设置界面，能看到：
   - **分辨率**下拉 — 这台相机支持的分辨率列表
   - **码率**下拉 / 滑块 — 支持的码率档位
   - **帧率** — 通常只有 30 fps 一档
5. 截图保存，就是该型号的"权威支持集"

不同固件版本可能略有不同，升级固件后重新查一次最保险。

### 15.6 工程里怎么按型号定制

当前 Demo 对所有型号使用同一组 UI 预设。如果要做型号感知（比如 OA5 Pro 支持到 8 Mbps 但 OA2 只到 4 Mbps），改造方向：

**方案 A：Swift 层按 model 提供预设**

在 `DJI/DjiSettings.swift` 给 `SettingsDjiDeviceModel` 加方法：

```swift
extension SettingsDjiDeviceModel {
    func supportedBitrates() -> [UInt32] {
        switch self {
        case .osmoAction5Pro, .osmoAction6, .osmo360:
            return [2, 4, 6, 8, 10, 12, 16, 20].map { $0 * 1_000_000 }
        case .osmoAction4:
            return [2, 4, 6, 8, 10, 12].map { $0 * 1_000_000 }
        case .osmoAction3:
            return [2, 4, 6, 8].map { $0 * 1_000_000 }
        case .osmoAction2:
            return [2, 4, 6].map { $0 * 1_000_000 }
        case .osmoPocket3:
            return [2, 4, 6, 8, 10].map { $0 * 1_000_000 }
        case .unknown:
            return [2, 4, 6].map { $0 * 1_000_000 }   // 保守默认
        }
    }

    func supportedResolutions() -> [SettingsDjiDeviceResolution] {
        // 目前 Moblin 所有型号都是这三档
        return [.r480p, .r720p, .r1080p]
    }
}
```

⚠️ 上表的档位**是示例猜测值**，实际数字必须你用 DJI Mimo 反查每台相机后回填。

**方案 B：通过 facade 暴露给 ObjC**

在 `DJI/DJIStreamController.swift` 加 @objc 方法：

```swift
@objc public static func supportedBitrates(forModelName modelName: String) -> [NSNumber] {
    let model = SettingsDjiDeviceModel(rawValue: modelName) ?? .unknown
    return model.supportedBitrates().map { NSNumber(value: $0) }
}
```

然后 UI 侧选中设备（`DJIDiscoveredPeripheral.modelName`）后动态调整 segmented control 的选项。

### 15.7 实机测试模板

想确认某型号具体支持什么，用 Demo 跑一轮测试，填这张表：

| 组合 | 相机反应 | 实际推流参数 |
|------|---------|-------------|
| 480p / 25fps / 2 Mbps | 接受 / 拒绝 / 沉默 | (待填) |
| 480p / 30fps / 4 Mbps | | |
| 720p / 25fps / 4 Mbps | | |
| 720p / 30fps / 6 Mbps | | |
| 1080p / 30fps / 6 Mbps | | |
| 1080p / 30fps / 10 Mbps | | |
| 1080p / 30fps / 16 Mbps | | |
| 1080p / 30fps / 20 Mbps | | |

**怎么判断"实际推流参数"**：
- 接收端收到第一个关键帧，解码后从 `CMSampleBuffer` 的 `formatDescription` 读 `CMVideoFormatDescriptionGetDimensions(...)`
- 或直接从 RtmpServerChunkStream 解出的 `@setDataFrame` metadata 里读 `width / height / videodatarate` 字段

在 `Ingest/RtmpServer/RtmpServerChunkStream.swift` 处理 Data 消息（type 0x12）的地方加日志，就能看到相机上报的真实 metadata。

### 15.8 已知相机的"沉默降级"行为

**重要**：相机对不支持的参数**通常不报错，而是悄悄降级**。例子：

- 发 "1080p + 20 Mbps" 给 OA3 — 相机可能实际推 1080p + 10 Mbps
- 发 "720p + 25 fps" 给 OA4 — 相机可能实际推 720p + 30 fps
- 发未知的 resolutionByte (比如 1440p) — 相机可能推 720p 或完全不启动

所以"能接受"≠"按你参数推"，必须读接收端的 metadata 验证。

### 15.9 结论与建议实操

1. **UI 上先给最保守的预设**：480/720/1080p × 2/4/6/8 Mbps × 30fps（这个组合在所有型号都 OK）
2. **想扩展高码率档位前先用 DJI Mimo 确认这台相机真的支持**
3. **设备选中后再按 model 调 UI 可用档位**（15.6 的方案 B）
4. **接收端读 metadata 做回显**：UI 显示"设定 1080p@10Mbps / 实际 1080p@6Mbps"，避免用户以为自己设置生效了
5. **未测过的参数组合记录在 15.7 的表里**，这个表随着测试积累会变成你们内部的权威能力矩阵

---

## 第十六章：SRT 推流模式（推到 PC 的 SRT Server）

### 16.1 为什么要上 SRT，它和 RTMP 有什么区别

本 Demo 原本是 **RTMP 本地接收 + iPhone 预览** 模式：

```
相机 ──(RTMP/TCP)──> iPhone (内置 RTMP server)
                      │
                      └─> VideoDecoder → PreviewView
```

切到 **SRT 推 PC** 模式后变成：

```
相机 ──(SRT/UDP)──> PC (SRT listener, 如 ffmpeg / OBS)
                     │
                     └─> PC 端播放/录制

iPhone 只做一件事：通过 BLE 把 SRT URL 下发给相机，然后旁观
```

对比：

| 维度 | RTMP 模式 | SRT 模式 |
|------|----------|---------|
| 传输协议 | TCP 1935 | UDP (任意端口) |
| 抗丢包 | 无 | 有 ARQ 重传 + FEC |
| 加密 | 无（裸流） | 有（passphrase，AES） |
| 延迟 | 2~4s | 可调（默认 120ms） |
| iPhone 角色 | 服务器（接收端） | 中继信使（只送 URL） |
| iPhone 上有预览 | ✅ | ❌（流不经过手机） |
| 看画面的地方 | iPhone 本身 | PC |

### 16.2 关键洞察：BLE 协议对 SRT 零感知

DJI 的 BLE 启动推流命令 payload 里，URL 部分只是一个**长度前缀的 UTF-8 字节串**：

```swift
// DJI/DjiMessage.swift
func djiPackUrl(url: String) -> Data {
    let data = url.utf8Data
    return Data([UInt8(truncatingIfNeeded: data.count), 0]) + data
}
```

代码不检查 `rtmp://` 还是 `srt://`，原样打包下发。**能不能走 SRT 完全取决于相机固件的 URL 解析器是否认 srt 方案**。

### 16.3 固件要求

OA5 Pro 原生 SRT 支持是从 **固件 01.03.0000**（2024 年底）开始的。检查：

- 相机 → 设置 → 关于设备 → 固件版本
- 低于 01.03 → DJI Mimo App → 固件升级

其他型号的 SRT 支持情况尚未完整测试（见第 15 章方法，用 DJI Mimo 的直播页面看有没有 SRT 选项）。

### 16.4 代码改动

**三处改动，都在 `ViewController.m`**：

1. **默认 URL 改为 SRT 地址**
   ```objc
   static NSString * const kDefaultSrtUrl =
       @"srt://10.12.23.96:32100?mode=caller&passphrase=tvulive@2026";
   ```

2. **onStartTap 按 URL scheme 分支**
   ```objc
   BOOL srtMode = [self isSrtUrl:url];
   if (srtMode) {
       // SRT: 跳过本地 RTMP server，只下发 BLE
       [self setSrtHintHidden:NO];
   } else {
       // RTMP: 原流程，启动本地接收 + 预览
       [RTMPIngestController.shared startWithPort:port streamKey:streamKey];
   }
   // URL 不变地传给 DJI facade（它只是塞给 djiPackUrl）
   [DJIStreamController.shared startLiveStream... rtmpUrl:url ...];
   ```

3. **预览区遮罩**：SRT 模式时盖一层 "SRT mode / stream is on the PC" 白字标签（`viewWithTag:9001`），让用户知道为什么画面不动。

**facade 层（`DJIStreamController.swift`）完全不变** — 它接收 `rtmpUrl:` 参数，内部直接转给 `DjiDevice.startLiveStream`，再一路进 `DjiStartStreamingMessagePayload.encode` → BLE。整个链路对 URL scheme 透明。

### 16.5 PC 端 SRT 服务器配置

相机 URL 里 `mode=caller` 表示 **相机主动连出**，所以 PC 必须是 **listener（监听）模式**。

#### 用 ffmpeg（最简单）

```bash
# 收流 + 存成 mpegts 文件
ffmpeg -i 'srt://0.0.0.0:32100?mode=listener&passphrase=tvulive@2026&pbkeylen=16' \
       -c copy -f mpegts recording.ts

# 收流 + 实时播放
ffplay 'srt://0.0.0.0:32100?mode=listener&passphrase=tvulive@2026&pbkeylen=16'
```

#### 用 srt-live-transmit（SRT 官方工具）

```bash
brew install srt    # macOS
# 或源码编译：https://github.com/Haivision/srt

srt-live-transmit 'srt://:32100?mode=listener&passphrase=tvulive@2026' 'file://con'
```

#### 用 OBS Studio

OBS 内置 SRT 输入源：
1. 添加 Media Source
2. Input: `srt://0.0.0.0:32100?mode=listener&passphrase=tvulive@2026&pbkeylen=16`
3. 关闭 "Restart playback" 选项以便持续接收

### 16.6 网络要求

- **手机和 PC 在同一 Wi-Fi**（本 Demo 的场景下是 `TVU-U6-2`）
- **相机也在同一 Wi-Fi**（BLE 命令会让相机连到 SSID 字段里填的 Wi-Fi）
- **PC 防火墙放行 UDP 32100 入站**（SRT 走 UDP，不是 TCP）
- **Client Isolation 必须关闭**（和 RTMP 模式一样）

macOS 临时放行（测试用）：
```bash
sudo pfctl -d    # 关闭 pf 防火墙（测试完记得开回）
```

Linux:
```bash
sudo ufw allow 32100/udp
```

### 16.7 SRT URL 参数说明

本 Demo 用的 URL：
```
srt://10.12.23.96:32100?mode=caller&passphrase=tvulive@2026
```

- **`srt://`** — scheme（必需）
- **`10.12.23.96`** — PC 的 LAN IP
- **`32100`** — UDP 端口（自选，两端要一致）
- **`mode=caller`** — 相机作为主动连出方，PC 必须是 listener
  - 反过来也可以：`mode=listener` 时相机监听，PC 去连，但这种方式相机要有公网可达地址，不适合手机 AP 场景
- **`passphrase=tvulive@2026`** — 加密密钥，两端必须一致
  - 长度 10~79 字符，不填则不加密
  - 注意：`@` 字符在 URL 里是合法的，但有些解析器会误识，建议换成无特殊字符的密钥做测试

其他可选参数：
- `pbkeylen=16` — 加密密钥长度（16/24/32 字节，对应 AES-128/192/256），默认 16
- `latency=200` — 端到端延迟缓冲（ms），默认 120，弱网环境下要拉大
- `streamid=xxx` — 类似 RTMP streamKey，PC 端多路复用时区分流

### 16.8 排错流程

#### 症状 1：BLE 状态能到 `streaming`，但 PC 上收不到连接

**大概率是相机固件不支持 SRT**。验证：

1. 在 PC 上抓包看有没有 UDP 到达：
   ```bash
   sudo tcpdump -i any -n udp port 32100
   ```
   - **一个包都没有**：相机根本没往 SRT URL 发，九成是固件旧
   - **有 UDP 包但 SRT 没握手**：passphrase/版本不对

2. 用 DJI Mimo App 试一下 SRT 直播（用同样的 URL），如果 Mimo 里能选 SRT 且能推通，说明固件支持；如果 Mimo 里直播选项只有 RTMP，就是固件不支持。

3. **降级验证** — 把 URL 改回 RTMP：
   ```
   rtmp://<PC-IP>:1935/live/dji
   ```
   PC 跑个 `nginx-rtmp` 或 `ffmpeg -listen 1 -i rtmp://0.0.0.0:1935/live/dji`，看 RTMP 能不能打通。RTMP 通而 SRT 不通 → 基本确定固件问题。

#### 症状 2：UDP 包到了 PC 但 SRT 握手失败

日志关键字（ffmpeg）：
- `Error: connection rejected due to wrong passphrase`
- `Connection timed out`

检查：
- **两端 passphrase 字符串完全一致**（包括 `@` 之类的特殊字符，不要被 shell 转义掉）
- **pbkeylen 一致**（默认 16，如果一端写了 24 / 32 另一端要对齐）
- **SRT 版本兼容**：相机用的是 SRT 1.4.x，PC 上 `ffmpeg -version | grep srt` 看版本，老版本（< 1.4）可能握手失败

#### 症状 3：握手成功但画面卡顿/花屏/丢帧

- 码率太高，Wi-Fi 吞吐跟不上 → 降到 6 Mbps 以下
- `latency` 太小 → URL 加 `&latency=500`（ms）
- SRT 有丢包统计，ffmpeg 接收端日志里有 `srt://recv,pkt=..., lost=..., retrans=...` 字段参考

#### 症状 4：相机连不上 Wi-Fi

和 SRT/RTMP 无关，和第 11 章的 BLE 排错流程一致 —— 这一步失败说明根本没到推流阶段。

### 16.9 怎么回切 RTMP 模式

只需要在 URL 输入框里粘一个 `rtmp://` 开头的地址：

- `onStartTap` 里的 `isSrtUrl:` 会自动识别协议
- RTMP 路径走原来的 `RTMPIngestController.startWithPort:streamKey:` 流程
- 预览会正常渲染
- SRT 提示标签自动隐藏

不需要改代码、不需要改配置。如果经常切换，可以把默认 URL（`kDefaultSrtUrl`）改成 iPhone 本机的 RTMP 地址。

### 16.10 可能的后续改造点

1. **加 protocol 切换 SegmentedControl**：显式让用户选 `RTMP / SRT`，避免输入错误
2. **记住上次的 URL**：用 UserDefaults 存 URL，下次启动恢复
3. **相机能力探测**：startLiveStream 失败后（比如固件不支持 SRT），UI 弹提示引导升级
4. **上 SRT 接收端到 iPhone**：如果也想在 iPhone 预览 SRT 流，需要把 Moblin 的 SRT 代码搬回来（之前删掉的 `Ingest/HaishinKit/Srt/` 那几个文件），还要加 libsrt SPM 依赖，工程量较大
5. **统计面板**：SRT 协议本身提供丰富的链路指标（`SrtPerformanceData`），可以显示实时 RTT、丢包率、重传率

---

# 第三部分：iOS 端预览、延迟优化与平滑队列

> 本部分记录从"推流到 PC 测试"改造为"推流到 iOS 端本地预览"，以及后续延迟优化和画面平滑的全过程。
> 所有改动均在 `ViewController.m`、`RTMPIngestController.swift`、`RtmpServer.swift`、`SettingsRtmpServer.swift`、`VTDecompressionSession+Extension.swift` 中。

---

## 第十七章：推流目标从 PC 改为 iOS 端预览

### 17.1 改动背景

第十六章完成了 SRT 推流到 PC 的模式。下一步目标是回归 RTMP 本地预览模式：相机通过 iPhone 个人热点接入同一局域网，将 RTMP 流推送到 iPhone 自身的内嵌服务器，在 iPhone 屏幕上实时预览画面。

### 17.2 默认 URL 改动（`ViewController.m`）

```objc
// 旧：指向 PC IP
static NSString * const kDefaultSrtUrl = @"rtmp://172.16.109.107:1935/live/drone";

// 新：指向 iPhone 热点固定 IP
static NSString * const kDefaultStreamUrl = @"rtmp://172.20.10.1:1935/live/dji";
```

iPhone 作为个人热点时，其对外 IP 固定为 `172.20.10.1`，相机连接到热点后即可访问该地址。

### 17.3 自动获取本机 Wi-Fi IP

通过 `getifaddrs` 读取 `en0`（Wi-Fi 接口）的 IPv4 地址，动态构建 RTMP URL：

```objc
#include <ifaddrs.h>
#include <arpa/inet.h>

- (NSString *)currentLocalIP {
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *iface = interfaces; iface != NULL; iface = iface->ifa_next) {
            if (iface->ifa_addr && iface->ifa_addr->sa_family == AF_INET
                && strcmp(iface->ifa_name, "en0") == 0) {
                address = [NSString stringWithUTF8String:
                    inet_ntoa(((struct sockaddr_in *)iface->ifa_addr)->sin_addr)];
                break;
            }
        }
    }
    freeifaddrs(interfaces);
    return address ?: @"172.20.10.1";  // fallback: Personal Hotspot IP
}
```

App 启动时自动填入 RTMP URL，适配 Wi-Fi 直连和热点两种场景。

---

## 第十八章：延迟优化

### 18.1 延迟来源分析

从相机到 iPhone 首帧上屏，初始约 3～4 秒，经分析各阶段贡献如下：

| # | 位置 | 问题 | 影响 |
|---|------|------|------|
| 1 | `SettingsRtmpServer.swift` | `latency` 默认 2000ms | ~2s |
| 2 | `RTMPIngestController.swift` | 未调用 `setAttachmentDisplayImmediately()` | ~500ms–1s |
| 3 | `RtmpServer.swift` | TCP `noDelay` 被注释 | ~40–200ms |
| 4 | `VTDecompressionSession+Extension.swift` | `_EnableTemporalProcessing` 允许 B 帧重排缓冲 | ~50–100ms |

### 18.2 修复一：TCP No-Delay

```swift
// RtmpServer.swift
let options = NWProtocolTCP.Options()
options.noDelay = settings.noDelay   // 由 UI 控制，默认 true
```

Nagle 算法会将小包攒批，对视频帧传输引入 40～200ms 额外延迟。

### 18.3 修复二：去掉解码器 B 帧重排

```swift
// VTDecompressionSession+Extension.swift
static let defaultDecodeFlags: VTDecodeFrameFlags = [
    ._EnableAsynchronousDecompression,
    // _EnableTemporalProcessing 已移除
    // DJI 直播流不含 B 帧，此 flag 只增加延迟
]
```

`_EnableTemporalProcessing` 允许解码器缓存多帧做显示顺序重排（B 帧场景），DJI 直播流无 B 帧，移除后无副作用。

### 18.4 修复三：`setAttachmentDisplayImmediately`（低延迟阶段）

`AVSampleBufferDisplayLayer` 默认按 PTS 排队等待，不加此标记会积压约 1 帧缓冲。追求最低延迟时在入队前设置：

```swift
sampleBuffer.setAttachmentDisplayImmediately()
```

**注意**：此标记与 PTS 平滑模式互斥，启用平滑队列时需移除（见第十九章）。

### 18.5 修复结果

| 阶段 | 修复前 | 修复后 |
|------|--------|--------|
| 初始延迟 | 3～4s | ~1s |
| 优化后延迟 | ~1s | ~300–500ms |

---

## 第十九章：UI 可调参数与平滑队列

### 19.1 新增 UI 控件

`ViewController.m` 新增三个运行时可调参数，在 Start 前设置：

| 控件 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| Buffer (ms) | UITextField（数字） | 0 | 给每帧 PTS 加偏移，值越大 layer 缓冲越多，画面越平滑但延迟越高 |
| TCP No-Delay | UISwitch | ON | 禁用 Nagle 算法，降低 TCP 层延迟 |
| Smooth Queue | UITextField（数字） | 3 | 抖动吸收队列上限（帧数），超出时丢最旧帧 |

参数通过 `RTMPIngestController` 的 `@objc` 属性传递：

```swift
@objc public var latency: Int32 = 0       // → SettingsRtmpServerStream.latency
@objc public var noDelay: Bool = true     // → SettingsRtmpServer.noDelay
@objc public var frameQueueSize: Int = 3  // → SmoothFrameQueue.targetSize
```

ObjC 侧赋值：
```objc
RTMPIngestController.shared.latency = (int32_t)[self.latencyField.text integerValue];
RTMPIngestController.shared.noDelay = self.noDelaySwitch.isOn;
NSInteger queueSize = [self.queueSizeField.text integerValue];
RTMPIngestController.shared.frameQueueSize = queueSize > 0 ? queueSize : 1;
[RTMPIngestController.shared startWithPort:port streamKey:streamKey];
```

### 19.2 键盘收起

数字键盘无 Return 键，需两种方式收起键盘：

1. **点空白区域**：`viewDidLoad` 注册 `UITapGestureRecognizer` → `[self.view endEditing:YES]`
2. **数字键盘 Done toolbar**：`latencyField` / `queueSizeField` 的 `inputAccessoryView` 设为带 Done 按钮的 `UIToolbar`

### 19.3 SmoothFrameQueue 设计

位于 `RTMPIngestController.swift` 末尾，不新增文件。

**核心结构：**

```swift
final class SmoothFrameQueue {
    private var frames: [CMSampleBuffer] = []
    private let targetSize: Int          // 队列上限（抖动吸收）
    private let lock = NSLock()          // 保护跨线程的 frames 数组
    private var displayLink: CADisplayLink?

    // 速率匹配状态
    private var lastOutputWallTime: Double = 0
    private var avgFrameDuration: Double = 1.0 / 30.0  // 自适应帧率
    private var lastFramePts: Double = -1
}
```

**关键设计决策：**

**1. 不使用"填满后才播放"（fill-first）**

早期版本在队列达到 `targetSize` 帧前不输出任何帧。问题：一旦队列低于阈值就暂停，导致周期性卡顿。

正确做法：有帧即输出，`targetSize` 只作为内存上限（丢最旧帧）。平滑由 `AVSampleBufferDisplayLayer` 的 PTS 调度负责。

**2. 速率限制（Rate Limiting）**

`CADisplayLink` 以 60Hz 触发，但流只有 30fps。不限速的话出帧速度是入帧的 2 倍，队列瞬间清空：

```swift
let wallNow = link.timestamp
guard wallNow - lastOutputWallTime >= avgFrameDuration * 0.9 else { return }
```

帧率通过相邻 PTS 差值自适应估计（EMA，权重 0.1），支持 25/30/60fps 流：

```swift
let diff = pts - lastFramePts
if diff > 0.005 && diff < 1.0 {
    avgFrameDuration = avgFrameDuration * 0.9 + diff * 0.1
}
```

**3. 不使用 `setAttachmentDisplayImmediately()`（平滑模式）**

该标记让 layer 忽略 PTS 立刻渲染，完全绕过 layer 的平滑调度。哪怕 `latency=1000ms`，帧也会立刻上屏，平滑设置形同虚设。

移除该标记后，layer 按 PTS 调度渲染：
- `latency=0ms`：PTS ≈ 当前时刻，layer 近乎立刻显示（低延迟）
- `latency=1000ms`：PTS = 当前时刻 + 1s，layer 缓冲 1 秒后平滑输出

### 19.4 延迟 vs 平滑参数速查

| 场景 | Buffer (ms) | Queue | No-Delay | 效果 |
|------|------------|-------|----------|------|
| 最低延迟 | 0 | 1 | ON | ~300–500ms 延迟，可能轻微抖动 |
| 均衡 | 200–500 | 3–5 | ON | 延迟适中，日常使用 |
| 平滑优先 | 1000 | 5–10 | ON/OFF | ~1.5s 延迟，非常平滑 |

### 19.5 数据流总览

```
DJI Osmo Action 5 Pro
    │ RTMP over Wi-Fi (TCP)
    ▼
RtmpServer (NWListener :1935, noDelay 可调)
    │ FLV Video Tag (H.265 HEVC / H.264 AVC)
    ▼
RtmpServerChunkStream
    │ CMSampleBuffer，PTS = systemTimeAtStart + videoTimestamp + latency(ms)
    ▼
VideoDecoder (VTDecompressionSession, 无 _EnableTemporalProcessing)
    │ decoded CVImageBuffer → CMSampleBuffer
    ▼
SmoothFrameQueue (NSLock + CADisplayLink 60Hz)
    │ 速率限制：avgFrameDuration * 0.9 门限
    │ 上限：targetSize 帧，超出丢最旧
    ▼
AVSampleBufferDisplayLayer
    │ PTS 调度（无 DisplayImmediately）
    ▼
iPhone 屏幕预览
```
