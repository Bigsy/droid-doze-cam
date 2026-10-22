# DroidDozeCam

**Use your Android phone as a Mac webcam—even while the phone is locked and its screen is off.**

**No app to install on your phone. No root.** Enable USB debugging once, authorize your Mac, and connect a USB data cable. After that, you can leave the phone locked: opening **DroidDozeCam** in a Mac video app starts the camera; closing the last camera stream stops it.

DroidDozeCam is a macOS menu bar app. Video travels over USB and is processed locally on your Mac. It provides video only, with no microphone, recording, or cloud relay built into the app.

## What you need

- A Mac running **macOS 13 or later**. Apple Silicon is the tested platform; Intel hardware is unverified.
- An **Android 12 or later** phone and a **USB data cable**.
- USB debugging enabled and your Mac authorized on the phone.
- The signed, notarized **Apple Silicon DMG** from [Releases](https://github.com/Bigsy/droid-doze-cam/releases). This is a developer preview.

Locked, screen-off capture has been tested on a **Samsung Galaxy S23 Ultra**, with Photo Booth and Google Meet in Chrome. That locked-phone coverage is from earlier builds; see [verification status](docs/VERIFICATION.md) for current build and device checks. Other phones and firmware may behave differently. The initial USB authorization requires unlocking the phone; normal capture on the tested phone does not.

## One-time phone setup: enable USB debugging

ADB is Android's built-in debugging connection. **You do not install ADB or a companion app on the phone.**

1. Open **Settings → About phone → Build number**. On Samsung, look under **About phone → Software information → Build number**.
2. Tap **Build number seven times**. Enter your phone PIN if asked.
3. Return to Settings and open **Developer options** (sometimes under **System**). Turn on **USB debugging**.
4. Connect the phone to your Mac with a USB data cable. Open DroidDozeCam's **Settings → Setup**; if ADB is missing on the Mac, choose **Download ADB…** and accept Google's terms, or select an existing ADB installation.
5. Unlock the phone and accept **Allow USB debugging?** for your Mac. Select **Always allow from this computer** for your own Mac.

**That's all the phone setup. You can now lock it and turn the screen off.** You do not need to open a camera app, keep the phone awake, or install an APK.

Menu names vary by manufacturer. See Google's [Developer options instructions](https://developer.android.com/studio/debug/dev-options) and [ADB authorization guide](https://developer.android.com/tools/adb#Enabling).

## Set up the Mac and start a call

1. Download **DroidDozeCam-macos-arm64.dmg** from [Releases](https://github.com/Bigsy/droid-doze-cam/releases), open it, and drag **DroidDozeCam** into **Applications**.
2. Open **DroidDozeCam.app** from `/Applications`.
3. In **Settings → Setup**, complete the phone setup above, then choose **Set Up Camera…**.
4. Approve the camera extension when macOS asks.
5. In your video app, select **DroidDozeCam** as the camera.

The login service starts USB capture only while an app uses the camera and stops it when the last stream closes. The menu bar icon shows whether the service is ready, starting, streaming, reconnecting, or needs attention. Closing the menu bar app does not stop the service.

Use **Settings → Capture** to choose the phone camera, output size, frame rate and bitrate. With a phone connected, it also reads the available source sizes, frame rates, zoom range and H.264 encoders.

- **Source size:** leave Automatic selected for normal use, or choose a size reported by the phone. Output size is what the Mac video app receives.
- **Camera zoom:** drag the smooth slider or type a ratio in the live readout beside it, to one decimal place. Zoom happens on the phone before the video is encoded. The phone decides whether this uses lens switching or digital zoom.
- **Camera torch:** enables the camera light when the selected camera supports it.
- **H.264 encoder:** leave Automatic selected unless you need to try another encoder listed by the phone.

Camera selection, source size, phone zoom, torch and encoder are saved per phone. Changing these settings restarts capture; the zoom slider applies when released. Changing cameras resets source size, zoom and torch for that selection. Reported modes are hints, not guarantees; unlisted frame rates remain available to try.

**Settings → Image** provides live rotation, mirroring, fit/fill, **Mac crop** and background blur with a strength slider. Mac crop enlarges the received image independently of phone-side zoom.

The service defaults to 1080p with a maximum of 60 fps. It requests 30 fps when the receiving app uses 30 fps or less. Higher resolutions and frame rates depend on the phone, USB connection and receiving app; requested rates are not guaranteed.

## Troubleshooting

- **Phone missing:** use a data-capable cable, check USB debugging, and reconnect the phone.
- **Phone unauthorized:** unlock it and accept the USB debugging prompt. If authorization expires or is revoked, approve the Mac again.
- **No picture:** check that Android camera access is enabled and close other apps using the phone camera. Try Automatic source size and encoder, 30 fps, 1× camera zoom and torch off. In **Settings → Setup**, try **Restart Camera Service**.
- **Camera missing in Mac apps:** check the Setup checklist and approve the camera extension. An unsigned development build cannot activate it.
- **A different phone:** connect it and run **Set Up Camera…** again to select it for the service.

To remove the camera and login service, choose **Settings → Setup → Remove Camera Setup…**. Once macOS has deactivated the extension (restart if requested), remove the app from `/Applications`.

## How it works

DroidDozeCam uses ADB to run a temporary, checksum-verified [scrcpy 5.0.1](https://github.com/Genymobile/scrcpy) camera helper on the phone. It is copied automatically for capture and removed on normal shutdown; **no Android app is installed**. The Mac decodes the USB video, applies image adjustments, and supplies frames to its Core Media I/O camera extension.

The phone remains locked during capture on the tested device. If its lock screen lights up during a call, the service turns it off when capture ends; it leaves an unlocked phone alone.

See [security and privacy](SECURITY.md) and [third-party notices](THIRD-PARTY-NOTICES.md). The inherited source also includes native UVC, iPhone Continuity Camera and optional Syphon/OBS paths; this fork focuses on Android over USB.

## Building from source

You need Xcode 15+ with its macOS SDK, Swift 5.9+, and Python 3. Builds and tests run locally.

```bash
git clone https://github.com/Bigsy/droid-doze-cam.git
cd droid-doze-cam
./scripts/build.sh --unsigned
./scripts/install.sh
```

This creates a development build for preview and diagnostics. **Using DroidDozeCam as a system webcam requires Apple signing and provisioning** for the app and camera extension. Follow the [signing and activation guide](docs/DROIDDOZECAM_SIGNING.md); the [release guide](docs/RELEASE.md) covers signed, notarized Apple Silicon DMGs.

Every build bundles the pinned scrcpy server and its license, downloading verified copies into `.cache/` when needed. ADB is installed separately on the Mac through Setup or your existing Platform-Tools installation. `make install` installs the existing `dist/DroidDozeCam.app`; it does not rebuild it.

Useful CLI commands after installation (stop the login service before manually running capture):

```bash
droiddozecam devices
droiddozecam cameras
# Machine-readable camera sizes, frame rates, zoom ranges and H.264 encoders
droiddozecam cameras --json
droiddozecam preview --source android --require-hardware
# Optional phone-side controls; use an encoder name from the cameras listing
droiddozecam preview --source android --camera-zoom 2 --camera-torch
# Exercise on-demand capture with a test pattern (requires the signed camera extension)
droiddozecam serve --source test
droiddozecam doctor --json
droiddozecam help
```

To run the local test suite:

```bash
./scripts/test.sh
```

The suite builds an unsigned test app outside `dist/`. It does not validate physical phones or activate a camera extension. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and device reports.

## Credits and license

Upstream attribution and third-party licenses are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

[MIT license](LICENSE) · [Third-party notices](THIRD-PARTY-NOTICES.md) · [Changelog](CHANGELOG.md) · [Report an issue](https://github.com/Bigsy/droid-doze-cam/issues)
