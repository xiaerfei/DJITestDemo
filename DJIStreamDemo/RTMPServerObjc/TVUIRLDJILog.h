//
//  TVUIRLDJILog.h
//  TVUIRLSDK
//
//  统一封装 DJI / RTMP 模块的日志输出.
//
//  动机:
//    - 这条链路上 (OSMORTMP + DJIStream) 散落了几十处 NSLog, 各文件各自维护前缀,
//      想全局开关 / 接 log4cplus / OSLog 时需要逐个改.
//    - 通过本宏统一收口, 后续只改这一处即可控制输出.
//
//  使用:
//      TVUIRLDJILog(@"dji-control: discovery timeout for %@", peripheralId);
//      TVUIRLDJILog(@"rtmp-server: VTDecompressionSessionCreate failed: %d", (int)status);
//
//  实际打印:
//      [TVU-DJI] dji-control: discovery timeout for ABCD
//      [TVU-DJI] rtmp-server: VTDecompressionSessionCreate failed: -123
//
//  原本使用 #if DEBUG ... NSLog ... #endif 包裹的高频日志保持原状,
//  仅把里面的 NSLog 替换为本宏即可.
//

#ifndef TVUIRLDJILog_h
#define TVUIRLDJILog_h

#import <Foundation/Foundation.h>

/// 统一前缀, 方便控制台 grep 过滤.
/// 通过宏拼接到 format 字面量左侧, 不引入运行时 string 构造开销, 也保留 NSLog 的 %@ 解析.
/// Release 构建下展开为 no-op, 不留运行时痕迹.
///
/// 注: 不能在另一个宏的 body 里写 `#if DEBUG`, 预处理指令必须在物理行首,
/// 宏展开后产生的 `#` 不会被解析成指令. 必须把 `#if` 提到外层.
#if DEBUG
    #define TVUIRLDJILog(fmt, ...) NSLog((@"[TVU-DJI] " fmt), ##__VA_ARGS__)
#else
    #define TVUIRLDJILog(fmt, ...) ((void)0)
#endif

#endif /* TVUIRLDJILog_h */
