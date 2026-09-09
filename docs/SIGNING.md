# macOS 签名、配置描述文件、公证与安装

## 为什么 CLI 仍然带有 .app

要让系统摄像头列表出现新设备，需要 Camera System Extension。Apple 的激活流程要求宿主应用包含扩展并放在 `/Applications`。因此本项目将命令行主程序放在一个支持可选预览窗口的 `.app` 内，而不是尝试让任意 `/usr/local/bin` 裸二进制静默安装驱动。

没有提供已签名二进制，是因为签名身份、私钥、配置描述文件、公证凭据属于发行者。脚本不会伪造这些材料，也不修改 SIP、Gatekeeper 或系统批准状态。

本说明描述正常签名部署路径；最终有效性由 Apple 的签名、profile 和系统校验决定。当前已完成 Mac 本机 CLI、原生预览和 Android + OBS 独立接收端验证，但这不等于完成开发者签名和系统扩展激活测试。

## 标识关系

以你实际拥有的标识为准，示例：

```text
Team ID:                 ABCDE12345
Host bundle ID:          dev.yourcompany.phonecam
Extension bundle ID:     dev.yourcompany.phonecam.camera
Shared macOS App Group:  ABCDE12345.dev.yourcompany.phonecam
CMIO Mach service name:  ABCDE12345.dev.yourcompany.phonecam
```

主程序启用 System Extension 安装能力、同一 App Group 与相机权限；扩展使用同一 App Group 和 App Sandbox。Mac App Group 的 Team-ID 命名规则不要与某些 iOS 工程中的 `group.` 示例盲目混用；以 Apple 相机扩展示例与当前账户能力配置为准。

`scripts/make-bundles.py` 生成 Host/Camera entitlements、Info.plist、Mach service 名和扩展内允许的 host ID。签名必须使用同一 Team，否则 producer 认证会失败。

## 准备身份与 profile

在你自己的 Apple Developer 账户/Xcode 中建立对应的 macOS app 标识与 Camera Extension 标识。最直观的方法是先在 Xcode 创建 macOS App 和 Camera Extension target，选择同一开发团队，为宿主添加 System Extension 与 App Groups，并让两个 target 使用相同组。然后获得与这两个精确 bundle ID、证书、部署方式匹配的配置描述文件。

可以在钥匙串查看可用身份：

```bash
security find-identity -v -p codesigning
```

正式站外分发使用 **Developer ID Application** 证书与相应 profile，并进行公证。开发签名必须使用相应 Apple Development 证书、profile 和允许的开发 Mac；不要把一个与 Developer ID 不匹配的开发 profile 放到正式包里。

查看 profile 内容：

```bash
security cms -D -i "$HOME/Signing/PhoneCam.provisionprofile"
```

本项目的 profile 检查器验证期限、Team ID、bundle ID、明确列出的 App Group 约束及宿主 System Extension 能力。这个本地检查不等同于 Apple 的最终验证，不能保证证书吊销状态、profile 与签名证书的全部关系或机器授权状态。

## 构建

```bash
export TEAM_ID="ABCDE12345"
export BUNDLE_ID="dev.yourcompany.phonecam"
export SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
export HOST_PROFILE="$HOME/Signing/PhoneCam.provisionprofile"
export EXT_PROFILE="$HOME/Signing/PhoneCamCamera.provisionprofile"
export BUILD_NUMBER=2
./scripts/build.sh --signed
```

更新时递增 BUILD_NUMBER。脚本先签扩展再签宿主，并开启 hardened runtime，不使用 `codesign --deep --sign` 进行模糊递归签名。`--deep` 仅用于最终验证整个包。

默认当前机器架构；`ARCHS="arm64 x86_64"` 分别编译后用 lipo 合并。此路径需要能面向这两种目标编译的 macOS SDK。使用系统动态 Swift 运行时；不要从其他操作系统复制伪造 SDK 或框架。

如只检查构建或直接探测系统原有摄像头：

```bash
./scripts/build.sh --unsigned
./dist/PhoneCam.app/Contents/MacOS/phonecam probe --source continuity
```

ad-hoc 包不能通过 `install-extension` 变成正常签名扩展。直接 probe 是否获得相机访问还取决于正常的 TCC 用户批准。

## Developer ID 公证

先在钥匙串保存凭据（不要把密码放入代码仓库、脚本或聊天）：

```bash
xcrun notarytool store-credentials phonecam-notary
NOTARY_PROFILE=phonecam-notary ./scripts/notarize.sh
```

脚本提交已签名 app 的 zip，等待 Apple 返回结果，然后 staple、验证 ticket 并进行 `spctl` 检查。失败必须根据 Apple 的返回日志处理，不能把“已提交”当作“公证已通过”。此脚本不是开发者账户开通或证书申请工具。

## 安装与启用

```bash
./scripts/install.sh
phonecam install-extension
phonecam status
```

扩展第一次启用需要本机管理员批准。审批入口随 macOS 版本变化；跟随系统通知查看隐私与安全性、登录项与扩展、Camera Extensions 等相关设置。可能需要重新打开会议软件才能刷新设备列表。

使用下面命令检查最终 app 的身份，而不是只查看 .build 中的裸 executable：

```bash
codesign -dv --verbose=4 /Applications/PhoneCam.app
codesign --verify --deep --strict /Applications/PhoneCam.app
systemextensionsctl list
phonecam doctor --json
```

不要在签名后替换 bundle 内的二进制、Info.plist 或资源；任何修改都需要重新签名，正式分发还需重新公证。Android server 默认放在用户 Application Support 而非 app bundle，安装它不会破坏 app 的签名封印。

## 卸载

先停止 `phonecam run` 和所有测试 probe，再运行：

```bash
phonecam uninstall-extension
```

返回 0 表示请求已完成；返回 2 表示系统要求重启完成。确认扩展不再处于启用状态后再删除宿主和启动脚本：

```bash
sudo rm -rf /Applications/PhoneCam.app
# 使用安装时打印的 CLI launcher 路径；Apple Silicon + Homebrew 默认如下：
sudo rm -f /opt/homebrew/bin/phonecam
```

这些命令只适用于确实由本项目安装的路径。用户下载的 server 文件在 `~/Library/Application Support/PhoneCam/`；按需自行删除，不要误删其他项目文件。

## 官方参考

- https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install
- https://developer.apple.com/documentation/systemextensions
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

## 可选 Syphon 集成与正式分发

当前 `--syphon` 从已安装 OBS 加载其 Syphon.framework，已验收的是本机 ad-hoc 构建。正式 hardened-runtime 包的动态库加载还受签名及 library validation 约束；不能据此承诺同样的外部框架路径在正式签名包中可用。

分发前需要选择并验证符合许可的框架打包、签名及加载方案，或者完成项目自己的摄像头扩展输出。不要把放宽系统保护当作通过签名验收的依据。
