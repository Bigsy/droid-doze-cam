# Platform support and Windows feasibility

Assessment date: 2026-09-09.

| Platform | Current scope |
|---|---|
| macOS 13+ / Apple Silicon | Product target; local Android + OBS pipeline verified |
| macOS / Intel | Source build option; no physical Intel validation |
| Linux | Portable `DroidDozeCamCore` tests only |
| Windows | Unsupported; no application or camera output binary |

## Can this app be cross-compiled from macOS to Windows?

**Not into a working camera application in its current form.** Swift itself supports Windows. The official Windows setup requires a Windows SDK and C++ toolchain; cross-architecture compiler support is separate from making Apple-only APIs available on Windows. [Swift Windows toolchain](https://www.swift.org/install/windows/manual/)

The current package declares the camera executables and media targets only inside `#if os(macOS)`. Their implementation depends on macOS frameworks and system services:

| Current component | What a Windows port would need |
|---|---|
| AVFoundation / Continuity Camera | Windows camera capture, plus a separate iPhone input strategy |
| VideoToolbox H.264 decoder | Windows decoding backend, such as Media Foundation |
| Core Image / Metal / CVPixelBuffer | Windows GPU rendering and frame-buffer interoperability |
| AppKit preview | Windows preview/window implementation |
| CoreMediaIO camera extension | Windows virtual-camera media source and registration |
| Syphon output | A Windows-compatible output bridge; Syphon is the current macOS integration |
| Darwin process, socket and resource handling | Windows implementations and cleanup/error tests |

Microsoft provides `MFCreateVirtualCamera` for a software camera source, with minimum client **Windows build 22000**. Adopting it would require a native media source and camera-privacy handling; it does not consume the existing CoreMediaIO extension. This is a possible port direction, not an implemented backend. [Microsoft API reference](https://learn.microsoft.com/en-us/windows/win32/api/mfvirtualcamera/nf-mfvirtualcamera-mfcreatevirtualcamera)

Apple's Continuity Camera is an iPhone-to-Mac feature. Its capture path cannot simply be carried over to Windows. Android's USB/ADB protocol code and the pure configuration/framing logic are candidates for reuse, subject to Windows tests. [Apple Continuity Camera](https://support.apple.com/en-us/102546)

## Checks performed

- Inspected `Package.swift` and the imports/backend implementations in the app, media and camera-extension targets.
- Local `swift sdk list` reported no installed cross-platform Swift SDKs.
- A local `swiftc -target x86_64-unknown-windows-msvc -typecheck` probe failed with `unable to load standard library for target 'x86_64-unknown-windows-msvc'` before framework resolution.

That local compiler failure establishes the current toolchain limitation; the Apple-framework dependencies explain why installing a Windows SDK alone would not complete the port. No Windows binary was produced or tested, and no Windows support is advertised for this release.
