# DroidDozeCam signing and activation

The unsigned build in `dist/DroidDozeCam.app` can capture and probe USB video. macOS will only activate its Core Media I/O camera extension after the host app and extension are signed with matching Apple team entitlements and provisioning profiles. Do not disable System Integrity Protection to work around signing.

This fork uses:

| Item | Value |
| --- | --- |
| Host app ID | `com.hedworth.usbwakecam` |
| Camera extension ID | `com.hedworth.usbwakecam.camera` |
| Shared App Group | `TEAM_ID.com.hedworth.usbwakecam` |
| Installed app | `/Applications/DroidDozeCam.app` |
| Camera shown to Mac apps | `DroidDozeCam` |

The host needs **System Extension** and **App Groups**. The camera extension needs the same App Group. Create matching macOS development profiles for both IDs using your Apple Developer team or Xcode automatic signing. The build script verifies both profiles before signing. Development signing does not require notarization for this machine.

```bash
export TEAM_ID="YOUR_TEAM_ID"
export SIGN_IDENTITY="Apple Development: YOUR_NAME (YOUR_TEAM_ID)"
export HOST_PROFILE="$HOME/Signing/DroidDozeCam.provisionprofile"
export EXT_PROFILE="$HOME/Signing/DroidDozeCamCamera.provisionprofile"
./scripts/build.sh --signed
./scripts/install.sh
droiddozecam install-extension
./scripts/install-service.sh USB_SERIAL
```

Approve the camera extension when macOS requests it. The login service then waits for a Mac app to open the `DroidDozeCam` camera, starts the USB camera stream, and stops it after the last client closes. The phone display stays off. Run `./scripts/uninstall-service.sh` to remove the login service. [Apple's camera extension guide](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o) explains the activation and approval steps; the [upstream signing guide](SIGNING.md) has more detail on profiles and notarization.

## Replacing an installed extension

macOS replaces an installed extension only for a new `BUILD_NUMBER`; `scripts/build.sh` defaults it to a timestamp, so every build qualifies. If the old extension is running when macOS replaces it (a camera app or producer is attached), `registerassistantservice` can resubmit the launchd job before the old one is gone; launchd logs `Submit job failed ... Operation already in progress` and `droiddozecam status` reports the camera as not visible. Close camera apps, stop `droiddozecam serve`, then build and install the next build number; replacing an idle extension registers cleanly. `scripts/install.sh` does this for an update: it stops the login service, waits up to 30 seconds for the old extension to exit and, when the extension is already approved, activates the new one before restarting the service and the menu bar app, both of which keep the extension running. It quits the menu bar app itself and reopens it afterwards. No reboot is needed, though old builds stay listed as `terminated waiting to uninstall on reboot` until the next restart.

The extension's sandbox cannot read the producer's bundle, so it authorizes the frame producer with the kernel's code-signing state for that PID (`csops`: valid signature, Apple Development or Developer ID validation category, identifier `com.hedworth.usbwakecam`, team ID).
