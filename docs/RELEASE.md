# Apple Silicon release

Releases are built on the signing Mac; there is no hosted build. The primary release is `dist/DroidDozeCam-macos-arm64.dmg`, with `dist/SHA256SUMS.txt`. It contains a Developer ID signed, notarized, stapled app and the pinned official scrcpy server with its Apache-2.0 license. ADB is downloaded by the app from Google after the user accepts Google's [SDK terms](https://developer.android.com/studio/terms), with a progress bar and SHA-256 check. The app keeps Platform-Tools 37.0.1 and its notice in the user's Application Support folder. It also accepts an existing ADB. Google's SDK terms restrict redistribution of the Platform-Tools package inside the release.

## One-time publisher setup

1. In Apple Developer **Certificates**, create a **Developer ID Application** certificate using the **G2 Sub-CA**. Generate its CSR in Keychain Access on the Mac that will sign the release, then import the downloaded certificate into that same keychain. A Developer ID Installer certificate is unnecessary for the DMG release.
2. In **Identifiers**, keep the existing host App ID `com.hedworth.usbwakecam` with System Extension and its App Group. Register a second explicit Mac App ID, `com.hedworth.usbwakecam.camera`, for the camera extension and assign the same App Group `YOUR_TEAM_ID.com.hedworth.usbwakecam`. If you maintain a separate fork, use your own registered bundle IDs consistently in the source and build scripts.
3. In **Profiles**, create a **Developer ID** profile for each App ID. Suggested names are **DroidDozeCam Host Developer ID** and **DroidDozeCam Camera Developer ID**. Download both `.provisionprofile` files. Development profiles tied to registered Macs cannot be used for a public release.
4. Store notarization credentials in the keychain with `xcrun notarytool store-credentials droiddozecam-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID`. The tool prompts securely for an app-specific password. Do not put passwords or API keys in the repository or shell history.

## Build and verify

Set the values below to the identity and files from your account. Use a build number greater than the last installed extension version.

```bash
export TEAM_ID=YOUR_TEAM_ID
export SIGN_IDENTITY='Developer ID Application: YOUR_NAME (YOUR_TEAM_ID)'
export HOST_PROFILE="$HOME/Downloads/DroidDozeCam_Host_Developer_ID.provisionprofile"
export EXT_PROFILE="$HOME/Downloads/DroidDozeCam_Camera_Developer_ID.provisionprofile"
export NOTARY_PROFILE=droiddozecam-notary
export BUILD_NUMBER=$(date +%Y%m%d%H%M%S)
./scripts/release.sh
```

The script builds **arm64 only**, downloads and verifies scrcpy-server 5.0.1 and its license, checks that neither profile is development or device-limited, signs with the hardened runtime and a secure timestamp, notarizes and staples the app, then creates, signs, notarizes and staples the DMG. It mounts the DMG read-only to verify the app and Applications shortcut, then generates a signed `dist/appcast.xml`. It refuses an Apple Development identity. Publish `dist/DroidDozeCam-macos-arm64.dmg` and `dist/SHA256SUMS.txt`. The ZIP is also retained locally.

## App update feed

The app embeds Sparkle 2.10.1, the official public Ed25519 key, and `https://raw.githubusercontent.com/Bigsy/droid-doze-cam/main/appcast.xml`. Automatic checks are opt-in; installation always requires the user's choice. Both the feed and DMG are signed, and Sparkle verifies the download before extraction. The checked-in initial feed is signed and empty until the first updater release is published.

The private signing key is held in the release Mac's login Keychain under account `com.hedworth.droiddozecam`. Keep it across releases and back it up securely. Never commit or print it. Packaging verifies that the Keychain public key matches the one embedded in the app.

1. Bump the public version in `Configuration.swift`, `scripts/make-bundles.py` and `scripts/test-cli.py`, and use a strictly increasing `BUILD_NUMBER` for both the app and extension. Packaging rejects older or reused public versions/builds against the checked-in feed.
2. Archive or remove a previous `dist/appcast.xml` before running `scripts/release.sh`; generation refuses to overwrite an existing feed. Run the signed/notarized release command above.
3. Upload the DMG and checksum to GitHub release **`v<VERSION>`**. The generated feed references that exact tag and `DroidDozeCam-macos-arm64.dmg` asset.
4. After the asset is available, publish `dist/appcast.xml` unchanged as the repository-root `appcast.xml` on `main`. Editing signed XML invalidates its signature. Release packaging does not push, upload assets or create a release.

Only releases whose generated feed you publish are offered, including prereleases. Keep preview releases out of this feed if it should serve stable releases only. Existing installations need one manual update to a build containing Sparkle.

Forks must generate a separate key and override **both** settings when building:

```bash
.build-arm64/artifacts/sparkle/Sparkle/bin/generate_keys --account YOUR_ACCOUNT
export SPARKLE_PUBLIC_ED_KEY="$(.build-arm64/artifacts/sparkle/Sparkle/bin/generate_keys --account YOUR_ACCOUNT -p)"
export SPARKLE_FEED_URL=https://YOUR_HOST/appcast.xml
export SPARKLE_ACCOUNT=YOUR_ACCOUNT
```

The generator's download URLs target this repository's GitHub Releases; forks must adjust those URLs in `scripts/sparkle_updates.py` too.

Before publishing, test an actual upgrade between two Developer ID signed, notarized builds on a separate Mac: opt-in persistence, no-update/error handling, update signature verification, service recovery after cancellation/interruption, extension replacement with camera apps closed, deferral while another app holds the old extension, and approval/restart handling. The automated suite checks configuration, feed generation, bundle layout and synthetic capture; it cannot establish the signed system-extension upgrade behavior.

Before promoting a preview to a stable release, test the DMG on a different Apple Silicon Mac. Leave its quarantine attribute intact. Open it, drag `DroidDozeCam.app` to Applications, launch it, and check the normal identified-developer first-open dialog. Confirm the camera extension activates and an Android phone works in a camera app. The stapled ticket helps Gatekeeper verify the app when offline. macOS still requires the user to approve the camera extension and camera permission.

## Recipient installation

1. Download and open the arm64 DMG, then drag the app onto its **Applications** shortcut.
2. Open DroidDozeCam. **Settings → Setup** shows the app, camera server, ADB, USB phone, login service, and camera extension. If ADB is missing, choose **Download ADB…**, review Google's terms, then choose **I Agree & Download**. The app downloads the pinned [official Mac package](https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip) with progress. You can also select an existing `adb` or use one installed by Homebrew in `/opt/homebrew/bin`.
3. Enable USB debugging on an Android 12+ phone, connect a USB data cable, and authorize the Mac on the phone.
4. Once the phone is authorized, choose **Set Up Camera** in the Setup tab. Approve the camera extension when macOS asks. Use the Capture and Image tabs for resolution, frame rate, camera, rotation, mirror, zoom, and blur.
5. Select **DroidDozeCam** in the video app. The login service starts the phone stream only while a Mac app uses the camera.

To uninstall, choose **Settings → Setup → Remove Camera Setup…** and wait for macOS to deactivate the camera extension. Restart if macOS requests it, then remove the app from `/Applications`. The downloaded ADB and saved settings remain in the user's Application Support and preferences until removed separately.
