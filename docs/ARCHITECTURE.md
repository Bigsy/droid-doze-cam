# DroidDozeCam architecture and runtime rules

## Capture, processing and three outputs

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

`preview` shows the processed picture and `probe` only prints statistics; both accept `--syphon`. `run` publishes through the CMIO sink to the project's own extension, which must be signed and activated separately. A working OBS path is not a substitute for accepting the DroidDozeCam extension.

On the iPhone path, "USB" describes how the device is used. DroidDozeCam does not implement Apple's private USB camera protocol; macOS manages Continuity Camera routing. The ADB path explicitly rejects devices that are not on USB.

## Threads and ownership

The main thread runs the NSApplication run loop and handles TCC, extension requests, signals, the optional preview window and Syphon server discovery. Syphon is created on the main thread so that its distributed discovery notifications have a running main run loop.

A capture/ADB worker thread performs the blocking connect and read calls. NativeCapture has its own AVCaptureVideoDataOutput callback queue; the callback only takes the CVPixelBuffer and writes it to the latest-frame mailbox. Each H.264 packet finishes decoding before the next is read, so jobs are never submitted to VideoToolbox without bound. The mailbox does an O(1) replacement under an NSLock; it is not a video queue that can keep growing.

The render queue processes each frame as it arrives, applies the transforms and hands the result to the selected output. A 0.1 second timer only covers the duration limit, saved settings, the Syphon privacy frame and statistics. The preview uses a separate one-frame mailbox and an AVSampleBufferDisplayLayer. Syphon converts the CVPixelBuffer to a Metal texture, normalizes the vertical orientation and waits for the GPU copy, which bounds the transfer backlog. The `run` path enqueues to the CMIO sink. A converted CVPixelBuffer is read-only once returned; nothing may keep writing to an IOSurface that is being sent. After a CMSampleBuffer is enqueued successfully it belongs to the CMIO consumer; when the enqueue fails, the producer balances its retain. The CLI never dequeues from the CMIO consumer queue, which would risk a double release and break the single producer, single consumer split.

In the extension, all state, property changes, consume completions and source timers run on one serial queue. `sync` checks a queue-specific key so that an extension callback already on that queue cannot deadlock by synchronizing again. The sink keeps at most one consume request outstanding and schedules the next one asynchronously, so synchronous callbacks cannot recurse and grow the stack. A generation token rejects late callbacks from a previous connection.

The source runs its timers only while it has consumers. Producer frames go out on arrival; a frame that follows the previous one too closely waits for the minimum spacing instead of being skipped, and a repeating timer resends a frame or sends black while the producer is quiet (`FramePacer`). During `run`, the CLI captures phone video even when no meeting app is reading; this keeps the connection state obvious and avoids restarting the phone camera when switching apps. **`serve` provides on-demand capture: the extension reports through the custom device property `wdmd` whether a Mac app is using the camera, `serve` starts or stops USB capture accordingly, and it writes its state to `~/Library/Application Support/DroidDozeCam/service-status.json` for the menu bar.**

## Formats and clocks

The source and sink both publish BGRA at five fixed sizes, and each negotiates its format separately. A phone input or source client of a different size costs one extra scaling pass, so the pipeline is most efficient when the input, the CLI bridge size and the meeting app's output size are the same.

Android H.264 parsing first reads the pinned version's codec header, then session records (which carry the dimensions) and each packet's flags, PTS and payload length. Annex-B is converted to AVC format with a four-byte NAL length prefix; the decoder is rebuilt when the SPS or PPS changes. Packets are limited to 16 MiB, and declared image dimensions and total pixel counts have their own limits. The SCID must be padded to eight hex digits as the server does, otherwise the adb forward connects to the wrong abstract socket.

The device PTS is only used for decode order, lag detection and keyframe resynchronization. Samples for the virtual camera use CMClockGetHostTimeClock. A monotonic clock prevents repeated or backward timestamps. The source sends with its own negotiated frame duration; the remote time declared in video packets is never used directly as a Mac host timestamp.

When the input has not updated for more than 1.5 seconds, the preview, Syphon and the extension each clear the stale picture; the extension source drops the original image and sends a reserved black frame. That black frame is allocated when the extension's renderer is created, so a client holding pool images cannot make the privacy fallback fail to allocate. Meeting apps may keep frames they have already received; this project cannot control a third-party client's caching.

## Exit and failure

SIGINT and SIGTERM set the cancellation flag; the USB socket checks it at poll intervals of at most 100 ms. Foundation child processes have timeouts, and are sent SIGTERM and then SIGKILL when necessary. Cleanup on a normal exit stops the source, drains callbacks, invalidates the decoder, stops the sink, and removes this session's forward and temporary server jar.

A failure before any frame has been captured is reported as a configuration error and is not retried forever. After frames have been captured, a failure reconnects to the same device by default, with a capped backoff. When the sink stops consuming for longer than a threshold, the process exits instead of swallowing errors indefinitely.

SIGKILL, a power loss or a system crash cannot run user-space cleanup. The phone side usually ends the server when its connection drops, but the Mac can be left with this session's ADB forward or temporary file; see troubleshooting in the acceptance document. The project never calls `adb kill-server`, which would affect Android Studio and other devices.

## Security scope

Frame producer authentication: the camera extension inspects the running producer with `csops`, the code-signing state the kernel validated when that process launched. It requires a valid signature, the expected host bundle identifier and team ID, and an Apple Development or Developer ID validation category. Ad-hoc and self-issued signatures are rejected, and an unavailable category also fails closed. A PID or a name alone is not accepted, and a failed check never falls back to letting any local program inject video. (`CMIOExtensionClient.signingID` can be "unknown" for a CLI inside a signed app, and the extension's sandbox cannot read the producer's bundle.)

The host bundle and the extension use the same Team and App Group. The camera extension is inside the host's `Contents/Library/SystemExtensions`. The App Group and Mach service name and the Team ID are generated once from build metadata, so they cannot drift between hand-written copies.

ADB is a separate developer tool that the user authorizes, and its permissions are usually far broader than a camera. In this flow DroidDozeCam only lists devices, queries the Android version, lists cameras and encoders, pushes the server, forwards a port, starts the camera server and deletes the files it created; after a call, `serve` also reads the phone's power and lock screen state and sends a sleep key event when the lock screen lit up. There is no silent authorization and no cloud relay, and USB debugging is never treated as a way around the phone's lock or its camera privacy settings.
