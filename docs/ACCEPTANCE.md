# Hardware acceptance and troubleshooting

The table below is an acceptance plan still to be carried out, not a report of tests that passed. Record results on the target Mac, the target phone and the actual meeting app versions.

## Re-checking the local OBS path

Run `droiddozecam preview --source android --require-hardware --syphon`, select the `[DroidDozeCam] DroidDozeCam` Syphon client in OBS and start its virtual camera. The independent client must select **OBS Virtual Camera**.

You can run `python3 docs/test-tools/WebcamValidation/server.py`, open the `127.0.0.1` address it prints, start the check and allow local camera access when the system asks. The page requires the receiving device to be named OBS Virtual Camera and stops otherwise; it captures no audio and uploads no picture. Statistics are written to `browser-evidence.jsonl` in the tool's directory; press Ctrl+C to stop the local server when finished.

- Compare the actual picture in the native preview, OBS and the browser: check up/down and left/right orientation and movement of the phone.
- Keep the browser receiving and close the DroidDozeCam window; confirm the output turns black.
- Restart the same DroidDozeCam command; confirm OBS reconnects by itself and the browser shows the phone picture again.
- Record the DroidDozeCam capture size and the OBS consumer size; OBS upscaling must not be counted as native 1080p from the phone.

This procedure checks local output through OBS. Signing of DroidDozeCam's own extension and the release acceptance below remain separate.

## Basic acceptance

| Scenario | Steps | Pass condition |
|---|---|---|
| macOS SDK build | `scripts/test.sh` | Swift core/media tests, build, link, bundle and code signature verification all pass |
| Normal signed install | `build.sh --signed`, notarize, install, activate | SIP stays enabled; the system allows the normal approval; `status` shows the device |
| Standalone test pattern | Terminal A: `droiddozecam run --source test`; a preview selects DroidDozeCam | The test bars keep moving; not a still image or a screen recording |
| Independent client read | A keeps running; B: `droiddozecam probe --device "DroidDozeCam" --duration 10 --json` | The probe can open the virtual source in parallel and reports a non-zero frame count; changes in the picture still need a visual check |
| iPhone | Connect over USB, trust the Mac, meet the Continuity Camera requirements; `--source continuity` | The phone picture is visible; record that macOS manages the routing, and do not take a successful run as proof of USB-only transport |
| Android UVC | Switch the phone to USB Webcam; `--source uvc` | The system sees the native UVC camera; bridged as DroidDozeCam, another client can read it |
| Android ADB | Android 12+, USB debugging authorized, server checksum passes | The log shows the encoded size and hardware decoding; the target app shows the phone picture |
| Several phones | Connect two matching devices | The CLI asks for an explicit ID or serial and never picks at random. The login service uses the phone set up last in Set Up Camera, and never a phone that was not set up |
| No wireless ADB | Try `--source android` with a wireless serial | Rejected even when the wireless device is authorized; a TCP device is never treated as USB |
| Several consumers | Two real camera clients open at the same time | No duplicate source timers; closing one does not affect the other |
| Transforms | 0/90/180/270, mirror, fit/fill | No stretching; bars or cropping match the option; text mirroring and rotation direction are correct |
| 720p/1080p/480p | Set each size, and change the size the meeting app negotiates | No wrong size, color shift or buffer corruption; source and sink may differ in size |
| Phone frame rate limits | Request 60 fps or a resolution the phone does not support | A clear error; no claim of success and no endless startup retries |
| Pause / unplug | Unplug once frames are steady | The extension input goes stale and turns black; the same device reconnects; no switch to another phone |
| Timestamps across disconnects | Unplug and replug several times; lock and unlock the phone | Client timestamps never go backward; no long backlog plays out after recovery |
| Permission denied | Deny camera permission, USB debugging authorization or the extension approval | A clear diagnosis; no repeated permission prompts and no bypass of authorization |
| Normal exit | Ctrl+C | The source stops; the sink closes; this session's forward and jar are removed; other ADB sessions are unaffected |
| Abnormal process exit | Force-quit the CLI on a test machine | The source goes stale and turns black; record the leftover forward; a `defer` that cannot run is not counted as a normal exit |
| Producer authentication | Try to inject with a different Team or an unapproved host signature | The extension refuses; a legitimate host from the same Team can start the sink |
| Long-run stability | Use the target app continuously for at least one hour | No unbounded memory growth, runaway temperature, accumulating video delay or repeated reconnects |

## Performance records

Record the Mac model, CPU architecture, macOS, Xcode, phone model, OS version, cable or hub, capture format, the format the client negotiated, encoder bitrate and whether VideoToolbox decoded in hardware. Use Activity Monitor or Instruments for CPU, memory, energy and GPU behavior.

"Lowest latency" should be measured by pointing the phone at a high-resolution timer and recording it together with the actual client preview; that covers exposure, encoding, USB, decoding, conversion and client buffering. The CLI's average received frame rate is not latency. Only the measurement method is given here; no performance numbers are invented for a target machine.

## Common problems

**DroidDozeCam is not listed as a camera:** check `droiddozecam status` and `systemextensionsctl list`, and confirm that what actually runs is `/Applications/DroidDozeCam.app/Contents/MacOS/droiddozecam`. Check whether this is only an `--unsigned` development build, whether the camera extension was approved and whether a restart is needed. Reopen the camera client to refresh its device list.

**The virtual camera is found but the picture is black:** the extension deliberately sends black when it has no input or the input is stale. Confirm `droiddozecam run` is still running and its processed count is growing. Rule out the phone with `--source test` first, then check the native or Android source log. A non-zero probe frame count does not rule out that it read black frames.

**Producer rejected / Start camera sink fails:** check that the host and the extension are from the same Team, that the bundle ID matches the generated `DroidDozeCamHostBundleIdentifier`, and that the provisioning profiles, certificate and signature seal are valid. Look at the DroidDozeCam CameraExtension rejections in the system log; do not change the authentication to allow everything.

```bash
log stream --predicate 'subsystem == "com.hedworth.usbwakecam"' --level info
```

**Android unauthorized:** unlock the phone and accept the USB debugging authorization. A charge-only cable carries no data. Some devices need to be replugged or authorized again. Device output can contain a sensitive serial; do not publish unredacted doctor JSON.

**Android has no USB marker:** to keep its USB-only policy, this version requires ADB to report `usb:` transport information. When a Platform-Tools and device combination does not provide that field, the device is refused conservatively instead of guessed at. Use recent official Platform-Tools and check `adb devices -l`. Do not skip the check by faking device information.

**The camera server does not start:** check Android 12+, the camera privacy toggle and whether another app holds the lens; lower the frame rate or resolution; use `--camera-id` or `--android-size` to choose a combination the device really supports. Some vendor ROMs may restrict camera access from the shell, and this release has not been verified model by model.

**Hash mismatch:** the server is not the pinned official version or the file is damaged. Run `scripts/setup-android.sh` again. Do not remove the SHA check or substitute a file of the same name from an arbitrary site.

**iPhone not visible:** go through Apple's Continuity Camera requirements: account, two-factor authentication, OS versions, Bluetooth and Wi-Fi, USB trust and what the phone is doing. Plugging in USB does not mean AVFoundation exposes any iPhone camera directly.

**High CPU:** prefer 720p30, reduce rotation and scaling, and keep the input, bridge and meeting app sizes the same. Check that the log says hardware decode. A lower bitrate mostly reduces the amount of compressed data and does not necessarily make the GPU conversion much cheaper. `--require-hardware` turns a software decode fallback into an explicit error.

**ADB forwards left after a force kill:** run `adb forward --list`, find the `localabstract:scrcpy_XXXXXXXX` entry for your DroidDozeCam session, and remove it by its exact serial and TCP port:

```bash
adb -s EXACT_SERIAL forward --remove tcp:EXACT_PORT
```

Only remove entries you have confirmed belong to DroidDozeCam; do not use `--remove-all` or `adb kill-server`, which affect other tools. A normal exit cleans up by itself; after SIGKILL or a power loss, user-space cleanup cannot be guaranteed.
