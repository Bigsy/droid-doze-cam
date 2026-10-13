# Apple Silicon GitHub release

The GitHub asset is `DroidDozeCam-macos-arm64.zip`. It contains a Developer ID signed, notarized, stapled app and the pinned official scrcpy server with its Apache-2.0 license. ADB is downloaded by the app from Google after the user accepts Google's [SDK terms](https://developer.android.com/studio/terms), with a progress bar and SHA-256 check. The app keeps Platform-Tools 37.0.1 and its notice in the user's Application Support folder. It also accepts an existing ADB. Google's SDK terms restrict redistribution of the Platform-Tools package inside our release ZIP.

## One-time publisher setup

1. In Apple Developer **Certificates**, create a **Developer ID Application** certificate using the **G2 Sub-CA**. Generate its CSR in Keychain Access on the Mac that will sign the release, then import the downloaded certificate into that same keychain. A Developer ID Installer certificate is unnecessary for the ZIP release.
2. In **Identifiers**, keep the existing host App ID `com.hedworth.usbwakecam` with System Extension and its App Group. Register a second explicit Mac App ID, `com.hedworth.usbwakecam.camera`, for the camera extension and assign the same App Group `HD342US4ZN.com.hedworth.usbwakecam`. Its development build previously used an Xcode wildcard profile, so this explicit ID is needed for release.
3. In **Profiles**, create a **Developer ID** profile for each App ID. Suggested names are **DroidDozeCam Host Developer ID** and **DroidDozeCam Camera Developer ID**. Download both `.provisionprofile` files. Development profiles tied to registered Macs cannot be used for a public release.
4. Store notarization credentials in the keychain with `xcrun notarytool store-credentials droiddozecam-notary --apple-id YOUR_APPLE_ID --team-id HD342US4ZN`. The tool prompts securely for an app-specific password. Do not put passwords or API keys in the repository or shell history.

## GitHub Actions release build

The manual [release workflow](../.github/workflows/release.yml) runs on an Apple Silicon `macos-15` runner. It builds the same arm64 app as the local release command, verifies the scrcpy downloads, signs, notarizes, staples, checks the extracted ZIP, and uploads `DroidDozeCam-macos-arm64.zip` as a workflow artifact. It does not publish a GitHub Release automatically; test the downloaded ZIP on another Mac first.

Configure these repository Actions secrets:

| Secret | Value |
| --- | --- |
| `APPLE_NOTARY_PASSWORD` | Apple ID app-specific password used by `notarytool` |
| `APPLE_DEVELOPER_ID_P12_B64` | Base64 of a `.p12` export containing the **Developer ID Application** certificate and its private key |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password chosen when exporting that `.p12` |
| `APPLE_HOST_PROFILE_B64` | Base64 of the host Developer ID provisioning profile |
| `APPLE_CAMERA_PROFILE_B64` | Base64 of the camera extension Developer ID provisioning profile |

On the signing Mac, open **Keychain Access → My Certificates**, select **Developer ID Application: Billy Hedworth (HD342US4ZN)** with its nested private key, then choose **File → Export Items…**. Save only that identity as a password-protected `.p12` outside the repository. Set the `.p12` password as `APPLE_DEVELOPER_ID_P12_PASSWORD` in GitHub's repository **Settings → Secrets and variables → Actions**. Stream the encoded file directly to the other secret without displaying it:

```bash
base64 < /path/to/DeveloperID.p12 | gh secret set APPLE_DEVELOPER_ID_P12_B64 -R Bigsy/droid-doze-cam
```

Set the profile secrets with the same `base64 < file | gh secret set NAME -R Bigsy/droid-doze-cam` pattern. Keep the `.p12` and its password out of the repository. To build, open **Actions → Notarized Apple Silicon release → Run workflow** and enter a new, increasing build number. Download the ZIP from the completed run's artifacts. After a separate Mac passes the installation and camera check below, attach the ZIP to a GitHub Release.

## Build and verify

Set the values below to the identity and files from your account. Use a build number greater than the last installed extension version.

```bash
export TEAM_ID=HD342US4ZN
export SIGN_IDENTITY='Developer ID Application: Billy Hedworth (HD342US4ZN)'
export HOST_PROFILE="$HOME/Downloads/DroidDozeCam_Host_Developer_ID.provisionprofile"
export EXT_PROFILE="$HOME/Downloads/DroidDozeCam_Camera_Developer_ID.provisionprofile"
export NOTARY_PROFILE=droiddozecam-notary
export BUILD_NUMBER=19
./scripts/release.sh
```

The script builds **arm64 only**, downloads and verifies scrcpy-server 3.3.4 and its license, checks that neither profile is development or device-limited, signs with the hardened runtime and a secure timestamp, notarizes, staples, then verifies the extracted release ZIP. It refuses an Apple Development identity. Upload only `dist/DroidDozeCam-macos-arm64.zip` to GitHub Releases; do not use GitHub's automatic source-code ZIP as the app download.

Test the downloaded ZIP on a different Apple Silicon Mac before publishing. Leave its quarantine attribute intact. Extract it, move `DroidDozeCam.app` to `/Applications`, open it, and check the normal identified-developer first-open dialog. Confirm the camera extension activates and an Android phone works in a camera app. The stapled ticket helps Gatekeeper verify the app when offline. macOS still requires the user to approve the camera extension and camera permission.

## Recipient installation

1. Download the arm64 ZIP from GitHub Releases, extract it, and move the app to `/Applications`.
2. Open DroidDozeCam. Its first-run **Camera Readiness…** checklist shows the app, camera server, ADB, USB phone, login service, and camera extension. If ADB is missing, choose **Download ADB…**, review Google's terms, then choose **I Agree & Download**. The app downloads the pinned [official Mac package](https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip) with progress. You can also select an existing `adb` or use one installed by Homebrew in `/opt/homebrew/bin`.
3. Enable USB debugging on an Android 12+ phone, connect a USB data cable, and authorize the Mac on the phone.
4. Once the phone is authorized, choose **Set Up Camera**. Approve the camera extension when macOS asks. Choose **Settings…** for resolution, frame rate, camera, rotation, mirror, zoom, and blur.
5. Select **DroidDozeCam** in the video app. The login service starts the phone stream only while a Mac app uses the camera.

To uninstall, choose **Remove Camera Setup…** from the menu bar icon and wait for macOS to deactivate the camera extension. Restart if macOS requests it, then remove the app from `/Applications`. The downloaded ADB and saved settings remain in the user's Application Support and preferences until removed separately.
