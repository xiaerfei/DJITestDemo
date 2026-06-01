# RTMPServerC 可优化空间记录

**配套文档：** `RTMPServerC.md`（架构与实现说明）
**依据：** 完整通读 `DJIStreamDemo/RTMPServerC/` 21 个模块（37 个 .c/.h，约 5400 行）+ `IngestObjc/` 桥接层 + `DJIStreamDemo.xcodeproj/project.pbxproj` 构建配置，技术细节零猜测。
**结论先行：** 热路径主体已优化到位。剩余空间集中在 **① 构建配置（零代码、最高 ROI）** 与 **② 热路径两处拷贝/调用开销**；正确性部分确认并补充了 `RTMPServerC.md` 第十一章。

> 标记说明：`[§11.x 已列]` = `RTMPServerC.md` 第十一章已提及，此处为代码确认 + 补充；其余为本次新增发现。

---

## 优先级总览

### P0 — 零代码 / 零风险，先做
- [ ] **开启 Release LTO**（`LLVM_LTO = YES`）→ 补全文档承诺的跨 TU 内联（详见一）
- [ ] 抓一次实机日志确认 DJI 实际发的 SetChunkSize 值（决定上一项收益幅度）

### P1 — 健壮性 / 正确性，改动小
- [ ] pipeline 协议错误走 `did_disconnect` 而非 `stop`（详见 3.1）
- [ ] 主解析循环 stop 后 `break`（详见 3.2）
- [ ] Window Ack 通告值与回 Ack 阈值自洽（详见 3.3）

### P2 — 性能进阶 / 扩展性，需先量化或视产品需求
- [ ] `emit_video_frame` 帧缓冲池化，消除每帧整帧 memcpy（详见 2.1）
- [ ] 评估 Release `-O2` vs 默认 `-Os`（详见一）
- [ ] 转发回调携带流标识，支持多路区分（详见 4.1）
- [ ] 8MB ring 延迟到 publish 成功后分配（详见五）
- [ ] tcUrl 路径匹配放宽 / AAC `mFormatFlags` 语义（实机验证项，详见 3.4 / 3.5）

---

## 一、构建配置层（最高 ROI，0 代码改动）

核实 `project.pbxproj`：全文件**无任何 `LLVM_LTO`**；`GCC_OPTIMIZATION_LEVEL = 0` 仅出现一次（`project.pbxproj:812`，Debug），Release 块未显式设置 → 继承 Xcode 默认 `-Os`。

| 项 | 现状 | 建议 |
|---|---|---|
| **LTO 未开启** | 无 `LLVM_LTO` | Release 设 `LLVM_LTO = YES`（或 `YES_THIN`） |
| Release 优化级别 | `-Os`（偏体积，默认） | 评估 `GCC_OPTIMIZATION_LEVEL = 2`（`-O2`，偏速度），配合 LTO 实测 |
| 部署目标不一致 | project Debug `IPHONEOS_DEPLOYMENT_TARGET = 26.2`（`:823`）、target 16.0（`:716/:754`） | 统一（target 覆盖 project，当前无害但易误导） |

**为什么 LTO 是关键：** `RTMPServerC.md` 第二章宣称"调用点无 vtable 间接跳转"。确无 vtable，但 chunk 解析热路径 `process_received`（`stream_connection.c:445`）对每个 chunk 都**跨编译单元**调用 `media_pipeline.c` 的一串单行函数 —— `set_message_timestamp` / `set_message_length` / `set_message_type_id` / `set_is_absolute_timestamp` / `next_chunk_data_size` / `append_chunk_bytes`（`media_pipeline.c:138-155`）。这些 `.c` 定义、`.h` 声明，**不开 LTO 无法内联**，每次都是真实 `call`/`ret` + 寄存器溢出。LTO 才能消除，并顺带跨模块做更多优化。

**收益幅度与客户端 chunk size 成反比。** 日志已有 `"chunk size from client: %u"`（`media_pipeline.c:426`）：若 DJI 仍用默认 128，一个 2MB I 帧被切上万 chunk，setter 洪流显著、LTO 收益明显；若已调到 4096+，收益中等。无论如何零风险、确定正收益。

---

## 二、热路径性能（代码层）

### 2.1 每视频帧一次 `malloc` + 一次整帧 `memcpy`（中优先级，收益随码率放大）
`emit_video_frame`（`media_pipeline.c:535-539`）：`CMBlockBufferCreateWithMemoryBlock(NULL, length, …)` 分配 + `CMBlockBufferReplaceDataBytes` 整帧拷贝。因 body 缓冲要给下一帧复用、VT 又是异步解码，这份拷贝目前**无法省**。真正零拷贝需把该帧 body 所有权转移给 CMBlockBuffer（自定义 `blockSource` 析构回收）+ 小型 body 缓冲池。4K/高码率下"每帧数 MB × 帧率"的 memcpy 是实打实开销；低码率可忽略。
- 顺带：`CMBlockBufferReplaceDataBytes` 返回值未检查（`media_pipeline.c:539`），失败会送残缺帧给 VT（低危，建议补判）。

### 2.2 PLL `remap_video_pts` 每帧 CMTime 通分运算（低优先级）
`stream_connection.c:666` 每帧在 VT 线程做多次 `CMTimeMakeWithSeconds`/`Subtract`/`Add`/`GetSeconds`，涉及 timescale 通分。可改纯 `int64` 微秒运算省通分。每帧一次、收益小、风险中，排后面。

### 2.3 `handle_connect` 三个控制消息分三次 `nw_connection_send`（低优先级，简单）
`media_pipeline.c:284-305`：WindowAck / SetPeerBandwidth / SetChunkSize 各自 `send_packet → dispatch_data_create → nw_connection_send`。可拼到一个 `tvu_irl_bytes_t` 一次发出，少 2 次系统调用 / 2 个小 TCP 段。冷路径（每连接一次），纯整洁性。

---

## 三、正确性 / 健壮性

### 3.1 pipeline 协议错误走 `stop` 而非 `did_disconnect` `[§11.1.1 已列]`
`media_pipeline.c` 所有协议错误（不支持 codec、body 过短、AMF 错误）调 `tvu_irl_stream_connection_stop()`，它**不**触发 `on_publish_stop`、**不**从 `connections[]` 移除、**不**销毁，连接滞留到 10s 超时才清理。建议错误路径改走 `tvu_irl_streaming_server_connection_did_disconnect()`（销毁是 async，栈上安全）。

### 3.2 主解析循环 stop 后不退出 `[§11.1.2 已列]`
`process_received` 的 `while (c->ring.used > 0)`（`stream_connection.c:445`）不检查 `lifecycle`，stop 后继续把 ring 残留喂给已 stop 的 decoder。建议循环顶部加 `if (atomic_load(&c->lifecycle) == IDLE) break;`。

### 3.3 Window Ack 通告值与回 Ack 阈值不一致 `[§11.3 已列]`
通告客户端 500000（`media_pipeline.c:285`），但服务器自身回 Ack 用 `window_ack_size` 默认 2_500_000（`stream_connection.c:280`）。建议 `handle_connect` 里把 `window_ack_size` 同步设为 500000，二者自洽。

### 3.4 `tcUrl` 精确匹配 `/live` 过严（实机验证项）
`media_pipeline.c:278` 要求 path **完全等于** `/live`。带 query 串、尾斜杠、或 `live/streamX` 形式都会被拒。建议放宽为前缀匹配或忽略 query；DJI 固件实测前定不下来。

### 3.5 AAC ASBD 的 `mFormatFlags = object_type` 语义存疑（实机验证项）
`audio_config.c:47` 把 FLV AAC objectType 直接塞进 `mFormatFlags`。CoreAudio 对 AAC 期望此处是 MPEG4 ObjectID；AAC-LC 下数值恰好一致所以能跑，其它 profile 未必。音频当前不消费（`RTMPIngestController.m:89` 空实现），联调启用音频时验证。

---

## 四、架构 / 扩展性

### 4.1 转发回调不携带流标识（中优先级，视产品需求）
`forward_video_sample(s, sb)` 等（`streaming_server.c:119-130`）与 `on_video_sample_buffer`（`RTMPIngestController.m:77`）都不带 `stream_key`/`camera_id`。`MAX_CONNECTIONS=8` 支持多路接入，但 delegate 无法区分帧来源。单路 Demo 无影响；若要做多机位预览/分发，需在回调签名加来源标识。

### 4.2 预览 enqueue 在 VT 线程执行（灰区）
`on_video_sample_buffer`（VT 线程）→ `previewController updateSampleBuffer` → `enqueueSampleBuffer`（`TVUIRLPreviewController.m:98`），全程未切线程。`AVSampleBufferDisplayLayer enqueue` 允许后台线程，但同帧读 `layer.status` 且可能与主线程 `layoutSubviews` 改 `layer.frame` 竞争属灰区。`RTMPServerC.md` 第八章已提示，建议显式确认或切到专用串行队列。

---

## 五、内存 / 资源

### 5.1 每连接握手即 `malloc(8MB)` ring（中低优先级）
`stream_connection.c:271` 连接一创建就分配 8MB，`MAX_CONNECTIONS=8` 峰值 64MB，握手中/空闲连接也占满。握手仅需 1537 字节。建议延迟到 publish 成功后再分配大 ring（或握手期用小缓冲），对 iOS 内存压力友好。单路场景无影响。

---

## 如果只做三件事
1. **开 Release LTO**（一）— 零代码、零风险，先看日志确认 chunk size 预估幅度。
2. **3.1 + 3.2** — 消除"错误连接滞留 10s"与"对死 decoder 空转"。
3. **3.3** — 一行修正，协议自洽。

性能进阶（先用 Instruments 量化再动）：**2.1 帧缓冲池化零拷贝** 与 **Release `-O2`**。

---

*生成时间：2026-05-31*
*基于源码完整通读 + 构建配置核实撰写。*
