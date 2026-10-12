# USB WakeCam signing and activation

The unsigned build in `dist/USBWakeCam.app` can capture and probe USB video. macOS will only activate its Core Media I/O camera extension after the host app and extension are signed with matching Apple team entitlements and provisioning profiles. Do not disable System Integrity Protection to work around signing.

This fork uses:

| Item | Value |
| --- | --- |
| Host app ID | `com.hedworth.usbwakecam` |
| Camera extension ID | `com.hedworth.usbwakecam.camera` |
| Shared App Group | `TEAM_ID.com.hedworth.usbwakecam` |
| Installed app | `/Applications/USBWakeCam.app` |
| Camera shown to Mac apps | `USB WakeCam` |

The host needs **System Extension** and **App Groups**. The camera extension needs the same App Group. Create matching macOS development profiles for both IDs using your Apple Developer team or Xcode automatic signing. On this Mac Xcode generated a host profile with System Extension enabled and a Mac Team profile accepted for the camera identifier. The build script verifies both profiles before signing. Development signing does not require notarization for this machine.

```bash
export TEAM_ID="YOUR_TEAM_ID"
export SIGN_IDENTITY="Apple Development: YOUR_NAME (YOUR_TEAM_ID)"
export HOST_PROFILE="$HOME/Signing/USBWakeCam.provisionprofile"
export EXT_PROFILE="$HOME/Signing/USBWakeCamCamera.provisionprofile"
export BUILD_NUMBER=5 # increase for each installed extension update
./scripts/build.sh --signed
./scripts/install.sh
usb-wakecam install-extension
./scripts/install-service.sh USB_SERIAL
```

Approve the camera extension when macOS requests it. The login service then waits for a Mac app to open `USB WakeCam`, starts the USB camera stream, and stops it after the last client closes. The phone display stays off. Run `./scripts/uninstall-service.sh` to remove the login service. [Apple's camera extension guide](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o) explains the activation and approval steps; the [upstream signing guide](SIGNING.md) has more detail on profiles and notarization.

## Replacing an installed extension

Bump `BUILD_NUMBER` for every replacement. If the old extension is running when macOS replaces it (a camera app or producer is attached), `registerassistantservice` can resubmit the launchd job before the old one is gone; launchd logs `Submit job failed ... Operation already in progress` and `usb-wakecam status` reports the camera as not visible. Close camera apps, stop `usb-wakecam serve`, then build and install the next build number; replacing an idle extension registers cleanly. No reboot is needed, though old builds stay listed as `terminated waiting to uninstall on reboot` until the next restart.

The extension's sandbox cannot read the producer's bundle, so it authorizes the frame producer with the kernel's code-signing state for that PID (`csops`: valid signature, identifier `com.hedworth.usbwakecam`, team ID).
