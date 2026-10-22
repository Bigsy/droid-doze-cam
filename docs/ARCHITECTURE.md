# DroidDozeCam 架构与运行约定

## 采集、处理与三种输出

```text
Android USB / ADB → pinned scrcpy server → H.264 / VideoToolbox ──┐
iPhone Continuity Camera / UVC → AVFoundation ──────────────────┤
                                                               ▼
                                               latest-frame mailbox (1)
                                                               │
                                               Core Image / Metal
                                                               │
                              ┌────────────────────────────────┼──────────────────────────┐
                              ▼                                ▼                          ▼
                       native preview                   Syphon Metal                CMIO sink (2)
                       AppKit window                         │                          │
                              │                              OBS                 DroidDozeCam extension
                              │                               │                 signing required
                              │                      OBS Virtual Camera                 │
                              └─────────────────────── camera consumers ────────────────┘
```

`preview` 显示处理后的画面，`probe` 只输出统计；这两个命令可附加 `--syphon`。`run` 则通过 CMIO sink 使用项目自带扩展，需要独立完成签名与激活。OBS 路径的成功不能替代 DroidDozeCam 扩展验收。

“USB”在 iPhone 路径上表示设备使用条件，不是 DroidDozeCam 自己实现的 Apple 私有 USB 摄像头协议。连续互通的路由由 macOS 管理。ADB 路径明确拒绝非 USB 设备。

## 线程与所有权

主线程运行 NSApplication 主循环，处理 TCC、扩展请求、信号、可选预览窗口及 Syphon 的服务器发现。Syphon 在主线程创建，确保分布式发现通知拥有运行中的主循环。

采集/ADB 工作线程执行阻塞连接和读取。NativeCapture 使用独立的 AVCaptureVideoDataOutput 回调队列；回调只提取 CVPixelBuffer 并写最新帧邮箱。每个 H.264 packet 解码完成后再继续，避免不限量向 VideoToolbox 提交任务。邮箱内部用 NSLock 做 O(1) 替换；它不是一条会不断增长的视频队列。

渲染队列按照 CLI 帧率取最新帧，完成变换后交给所选输出。预览使用独立的容量为 1 的邮箱与 AVSampleBufferDisplayLayer。Syphon 将 CVPixelBuffer 转为 Metal 纹理，统一上下坐标方向，并等待 GPU 拷贝完成以限制传输积压。`run` 路径向 CMIO sink 入队。转换后的 CVPixelBuffer 返回后视为只读，不能继续写入正在发送的 IOSurface。CMSampleBuffer 入队成功后所有权交给 CMIO 消费方；入队失败在生产方平衡 retain。CLI 不主动从 CMIO 的 consumer 队列 dequeue，以免双重释放或破坏生产/消费单一职责。

扩展所有状态、属性变更、consume 完成处理和 source 定时器放到一个串行队列。`sync` 检查 queue-specific key，防止扩展回调进入同一个队列后再次同步造成死锁。sink 最多保持一个 consume 请求；异步安排下一次请求，避免同步回调递归导致栈增长。generation token 拒绝上一次连接晚到的回调。

source 只在有消费者时运行发送定时器。CLI 在 `run` 期间仍主动采集手机视频，即使没有会议软件正在读取；这让连接状态更直观，也避免应用切换时重复启动手机相机。**DroidDozeCam 的 `serve` 提供按需采集：扩展通过自定义设备属性 `wdmd` 报告是否有 Mac 应用正在使用相机，`serve` 据此启动或停止手机的 USB 采集，并把当前状态写入 `~/Library/Application Support/DroidDozeCam/service-status.json` 供菜单栏显示。**

## 格式与时钟

Source 与 sink 均公布 BGRA / 三个固定尺寸；source 和 sink 可分别协商格式。手机输入或 source 客户端大小不同会进行一次额外缩放。因此最高效率是输入、CLI 桥接尺寸和会议软件的输出尺寸一致。

Android H.264 先解析固定版本的 codec header，再解析每个 packet 的 flags/PTS 和 payload 长度。Annex-B 转 AVC 格式的 NAL 长度前缀必须为 4 字节；SPS/PPS 改变时重建解码器。packet 最大 16MiB，声明图像维度及像素总数有额外上限。SCID 必须按 server 的规则补齐为 8 位十六进制，否则 adb forward 会连接错误的 abstract socket。

device PTS 只用于解码顺序、落后检测和 keyframe 重同步。虚拟相机最终样本使用 CMClockGetHostTimeClock。时钟单调器防止重复或倒退。source 用自己的协商 frameDuration 输出；视频包里声明的远端时间不能直接充当 Mac host timestamp。

当输入超过 1.5 秒未更新，预览、Syphon 与扩展各自清空过期画面；扩展 source 丢弃原图并发送预留的黑画面。黑画面在扩展 renderer 初始化时预分配，避免客户端持有池中图像导致隐私回退画面分配失败。不同会议软件自身可能保留已收到的历史帧，本项目无法控制第三方客户端的缓存策略。

## 退出与失败

SIGINT/SIGTERM 设置取消标志；USB socket 以不超过 100ms 的 poll 间隔检查取消。Foundation 子进程有超时，必要时先发 SIGTERM 再 SIGKILL。正常退出的清理包括源停止、回调排空、解码器失效、sink 停止、移除本次 forward 和临时 server jar。

首次未成功采集任何帧即出错，直接报告配置错误，不无限重试。成功采集后的失败默认重连原设备，采用有上限退避。sink 连续停止消费达到阈值时退出而不是无限吞掉错误。

SIGKILL、Mac 断电或系统崩溃无法执行用户态 defer。手机端连接断开通常会结束 server，但 Mac 可能残留本次 ADB forward 或临时文件；见验收文档的故障处理。项目不调用 `adb kill-server`，避免影响 Android Studio 或其他设备。

## 安全范围

对扩展的生产者认证检查 CMIOExtensionClient.signingID，以及 Security.framework 获取的进程代码签名是否满足 Apple anchor、Team ID、bundle ID。仅凭 PID 或名字不足以认证。此检查失败时拒绝，不退回“任何本地程序均可注入视频”。

主程序 bundle 与扩展使用同一 Team 和 App Group。相机扩展包含在主程序的 Contents/Library/SystemExtensions。App Group/Mach service 名和 Team ID 从构建元数据一次生成，避免手写多处配置漂移。

ADB 是一个独立的用户授权开发工具，权限通常远大于摄像头。DroidDozeCam 在本流程只执行设备枚举、系统版本查询、push server、forward、启动 camera server 与删除自己创建的文件。不存在静默授权、不存在云中继，也不会把 USB 调试当作可绕过手机锁定和相机隐私设置的权限。

## Frame producer authentication

The camera extension inspects the running producer with `csops`. It requires a valid signature, the expected host bundle identifier and team ID, and an Apple Development or Developer ID validation category. Ad-hoc and self-issued signatures are rejected; an unavailable category also fails closed.
