# 真机验收与故障排查

下表是待执行的验收计划，不是已经通过的测试报告。请在目标 Mac、目标手机和实际会议软件版本上记录结果。

## 本机 OBS 路径复验

`droiddozecam preview --source android --require-hardware --syphon`，OBS 选择 `[DroidDozeCam] DroidDozeCam` 的 Syphon 客户端并启动虚拟摄像机。独立客户端必须选择 **OBS Virtual Camera**。

可运行 `python3 docs/test-tools/WebcamValidation/server.py`，打开打印出的 `127.0.0.1` 地址，点击开始验收并按系统提示允许本机摄像头访问。页面要求接收的设备名称为 OBS Virtual Camera，否则停止；不采集音频、不上传画面。统计写到该工具目录的 `browser-evidence.jsonl`，结束后 Ctrl+C 关闭本地服务。

- 对照原生预览、OBS 和浏览器中的实际画面，检查上下、左右方向和手机动作。
- 保持浏览器接收，关闭 DroidDozeCam 窗口；确认输出转黑。
- 重启相同 DroidDozeCam 命令；确认 OBS 自动重连，浏览器恢复手机画面。
- 记录 DroidDozeCam 采集尺寸和 OBS 消费者尺寸，不能把 OBS 上采样当作手机原生 1080p。

此流程验证的是借助 OBS 的本机输出；DroidDozeCam 自带扩展的签名及下面的生产发布验收仍独立进行。

## 基本验收

| 场景 | 操作 | 通过条件 |
|---|---|---|
| macOS SDK 构建 | `scripts/test.sh` | Swift 核心/媒体测试、构建、链接、bundle 和代码签名验证均通过 |
| 正常签名安装 | `build.sh --signed`，公证，install，激活 | SIP 保持启用；系统允许正常批准；status 可见设备 |
| 独立测试图 | 终端 A `droiddozecam run --source test`；预览选择 DroidDozeCam | 测试条纹连续移动，不是静态图或屏幕录制 |
| 独立客户端读取 | A 继续运行；B `droiddozecam probe --device "DroidDozeCam USB Camera" --duration 10 --json` | probe 可以并行打开虚拟 source，输出非零帧；图像变化仍需视觉验证 |
| iPhone | 连接 USB、信任 Mac、满足连续互通；source continuity | 能看到手机画面；明确记录 OS 管理路由，不能把运行成功当作 USB-only 证明 |
| Android UVC | 手机切换 USB Webcam；source uvc | 系统可见原生 UVC；转接为 DroidDozeCam 后能被另一客户端读取 |
| Android ADB | Android 12+、授权 USB 调试、server 校验通过 | 日志能看到编码尺寸及硬件解码状态；目标应用可看到手机画面 |
| 多手机 | 接入两台可匹配设备 | 程序要求明确 ID/serial，不随机选择 |
| 禁止无线 ADB | 用无线 serial 尝试 source android | 即使无线设备已授权也拒绝；不得把 TCP 设备当 USB |
| 多消费者 | 两个真实摄像头客户端同时打开 | 不重复创建多个 source 定时器；关闭一个不影响另一个 |
| 变换 | 0/90/180/270、mirror、fit/fill | 无拉伸、黑边/裁剪符合选项；文本镜像与旋转方向正确 |
| 720p/1080p/480p | 分别设置尺寸，并改变会议应用协商尺寸 | 无错误尺寸、颜色偏移、缓冲区损坏；source 与 sink 可不同尺寸 |
| 手机限帧率 | 请求手机不支持的 60fps/分辨率 | 明确报错，不声称成功、不无限启动重试 |
| 暂停/拔线 | 稳定出帧后拔线 | extension 输入过期转黑；同一设备重连恢复；不切换其他手机 |
| 断线时间戳 | 多次拔插、手机锁屏/恢复 | 客户端时间戳不倒退，恢复后没有长时间积压播放 |
| 权限拒绝 | 拒绝相机权限、USB 调试授权或扩展批准 | 清楚诊断；不循环弹权限、不绕过授权 |
| 正常退出 | Ctrl+C | source停止；sink关闭；本次forward与jar清理；其他ADB会话不受影响 |
| 进程异常退出 | 测试机上强制结束 CLI | source过期转黑；记录残留 forward；不把不可执行 defer 当作正常退出 |
| 生产者认证 | 换 Team / 非批准的 host 签名尝试注入 | 扩展拒绝；合法同 Team 宿主可开始 sink |
| 长时稳定 | 目标应用连续使用至少1小时 | 无无界内存增长、温升失控、累计视频延迟或反复重连 |

## 性能记录

记录 Mac 型号、CPU 架构、macOS、Xcode、手机型号、系统版本、线缆/Hub、采集格式、客户端协商格式、编码码率、是否 VideoToolbox 硬件解码。使用 Activity Monitor / Instruments 看 CPU、内存、能耗与 GPU 行为。

“最低时延”应以手机拍摄高分辨率计时器并同时录入实际客户端预览的方法测量，包含曝光、编码、USB、解码、转换与客户端缓存。CLI 平均接收帧率不是时延。这里只给测量方法，不编造目标机器的性能数字。

## 常见问题

**找不到 DroidDozeCam USB Camera：** 先看 `droiddozecam status`、`systemextensionsctl list`，确认真正执行的是 `/Applications/DroidDozeCam.app/Contents/MacOS/droiddozecam`。检查是否只是 --unsigned 开发包，是否批准相机扩展，是否需重启。重开摄像头客户端以刷新设备枚举。

**能发现虚拟摄像头但画面全黑：** extension 在没有输入或输入过期时刻意输出黑画面。确认 `droiddozecam run` 仍在运行，processed 计数增长。先用 `--source test` 排除手机故障，再检查原生/Android source 日志。probe 的非零帧不能排除它读到了黑画面。

**producer 被拒绝 / Start camera sink 失败：** 检查宿主和 extension 是否同一 Team；bundle ID 是否与生成的 DroidDozeCamHostBundleIdentifier 一致；配置描述文件、证书、签名封印是否有效。用系统日志查看 DroidDozeCam/CameraExtension 的拒绝记录，不要把认证改成无条件允许。

```bash
log stream --predicate 'subsystem == "dev.flyfish.droiddozecam"' --level info
```

**Android unauthorized：** 手机上解锁并接受 USB 调试授权。仅充电线不能传数据。某些设备需重新拔插或重新授权。设备输出可能包含敏感 serial，不要直接公开未经脱敏的 doctor JSON。

**Android 没有 USB 标记：** 本版为了 USB-only 策略，要求 ADB 提供 `usb:` 传输信息。如果平台工具/设备组合不提供该字段，会保守拒绝而不会猜测。使用官方近期 Platform-Tools，检查 `adb devices -l`。不要通过伪造设备信息跳过检查。

**camera server 不能启动：** 检查 Android 12+、相机隐私开关、镜头是否被其他应用占用；减少帧率/分辨率；使用 `--camera-id` 或 `--android-size` 选择设备实际支持的组合。部分厂商 ROM 可能限制 shell 相机访问，当前交付没有逐机型验证。

**hash mismatch：** server 不是固定官方版本或文件损坏。重新执行 `scripts/setup-android.sh`。不要删除 SHA 校验或用随机网站的同名文件替代。

**iPhone 看不到：** 对照 Apple 连续互通要求排查账户、双重认证、系统版本、蓝牙/Wi-Fi、USB信任和手机使用状态。普通 USB 接上并不意味着 AVFoundation 会直接暴露任意 iPhone 摄像头。

**CPU 偏高：** 优先 720p30，减少旋转/缩放，使输入、桥接和会议软件尺寸一致。检查日志是否为 hardware decode。降低码率主要降低压缩数据量，并不一定显著降低 GPU 转换成本。`--require-hardware` 可让软件解码回退变成明确错误。

**强制杀进程后残留 ADB 转发：** 先 `adb forward --list`，找到你这次 DroidDozeCam 会话对应的 `localabstract:scrcpy_XXXXXXXX`，按确切 serial 和 tcp 端口删除：

```bash
adb -s EXACT_SERIAL forward --remove tcp:EXACT_PORT
```

只删除确认属于 DroidDozeCam 的条目，不要 `--remove-all` 或 `adb kill-server`，这些会影响其他工具。正常退出会自动清理；SIGKILL、断电不可能保证执行用户态清理。
