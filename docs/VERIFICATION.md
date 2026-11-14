# Verification status

The current source is a developer preview. Syntax checks and a source review are not a substitute for building, signing and testing the app on real hardware.

## Recorded device coverage

Earlier DroidDozeCam builds were reported working with a Samsung Galaxy S23 Ultra and an Apple Silicon Mac, using Photo Booth and Google Meet in Chrome. Opening the camera started USB capture, closing it stopped capture, and the phone remained locked with its screen off. These observations do not validate every Android device or the latest source changes.

The upstream project separately recorded Android → native preview → Syphon → OBS Virtual Camera → browser testing. That validates an earlier OBS route, not this fork's current system camera extension. Upstream attribution is in [third-party notices](../THIRD-PARTY-NOTICES.md).

## Current source review

### 0.1.1 release — 14 November 2026

The app and Apple Silicon DMG are Developer ID signed, notarized, stapled and accepted by Gatekeeper. Packaging mounted the DMG read-only and verified its embedded app and Applications shortcut. The download from GitHub matched the packaged DMG byte-for-byte, and the published feed matches the signed generated XML.

The final checks passed: 88 Swift tests, 10 bundle/update-tooling checks and 10 CLI integration checks. Recovery tests also cover carrying a deferred camera-extension upgrade and a failed service restart into a later app update, while rejecting malformed recovery data before stopping the service.

A live Sparkle update passed between notarized builds `20261114102002` and `20261114102252`, both displaying version 0.1.1. The older app discovered the release, downloaded and verified it, installed it and relaunched. The installed build number changed to the release build, its notarization ticket validated, and the login service restarted. Fingerprint comparisons confirmed that camera settings, configured phones, the service configuration and downloaded ADB were preserved without recording their contents. A subsequent check displayed “You're up to date.”

Another app retained the older 0.1.0 camera extension during this test. Recovery preserved that extension, restored the service, saved the pending upgrade and showed the expected waiting notice. Actual replacement after all camera clients exit, fresh-Mac installation, testing on a second Mac and a new end-to-end video call remain pending. This is still a developer preview.

### 0.1.1 updater candidate — 13 November 2026

The arm64 candidate builds and passes Developer ID signature verification, including Sparkle's nested helpers and the camera extension. The full local checks passed: 86 Swift tests, 10 bundle/update-tooling checks and 10 CLI integration checks. Update regression tests cover interrupted installs, service-restart failures, active-camera deferral, tab-separated extension listings and manual-upgrade detection.

The installed app's Updates tab was checked visually. Its manual update check retrieved the published, signed empty feed and displayed “You're up to date.” The published XML was also downloaded and verified with Sparkle's native signing tool. A temporary app DMG passed native signed-feed generation and verification.

The local installer preserved the running 0.1.0 camera extension because another app still held it open. On launch, the new app detected the older extension, waited for it to exit, then showed “Camera update waiting,” restored the login service and saved the retry state. The Settings window remained usable after dismissing the notice. At this stage the release was a draft; the completed notarization, packaging and live update results are recorded above.

### Earlier release checks

The public cleanup includes module/executable renaming, stricter producer authentication, reduced duplicate startup checks, test-pattern support and updated camera status reporting. It also migrates to scrcpy 5.0.1, handles the new codec/session/packet headers, discovers camera modes and encoders, and adds per-phone source size, zoom, torch and encoder controls. Local checks on 24 October 2026 passed: the signed arm64 build, 57 core tests, 10 media tests, 5 bundle-tooling checks and 10 CLI integration checks. A development-signed camera extension was activated and appeared in the Mac camera list. A short USB probe with the connected Samsung SM_S938B discovered camera modes and H.264 encoders, and captured video through scrcpy 5.0.1 using hardware decoding.

The 0.1.0 release app and DMG are Developer ID signed, notarized by Apple and stapled. The DMG is mounted read-only during packaging to verify its embedded app and Applications shortcut. Fresh-Mac installation, end-to-end video calls with the distribution build, locked-screen regression checks and longer hardware sessions remain pending; the release is a prerelease.

`./scripts/test.sh` runs the Swift tests, bundle-tooling checks, syntax checks, an unsigned app build and CLI integration checks. It does not install or activate a camera extension. Builds and tests run locally; this repository has no hosted CI.

The lease-file CLI test checks on-demand dispatch and termination. Actual test-pattern delivery through the camera extension must be checked with a correctly signed app. The signature tests reject platform and ad-hoc code; acceptance of the signed host still needs installation testing on supported macOS versions.

## Before distributing a new binary

- Run the full local test suite and verify the signed host and extension work together.
- Confirm upgrades from an earlier build preserve the login service, phone selection and camera approval.
- Check live blur strength, capture settings, frame rate and immediate stop behavior.
- Check frame pacing in a receiving app at 30 and 60 fps: motion stays even, with no skipped or bunched frames.
- Confirm scrcpy 5.0.1 starts with the phone already locked and screen off, and recovers after USB reconnect and encoder/session resets.
- Compare `droiddozecam cameras --json` with the phone's actual capture modes. Test Automatic and explicit source sizes, 30/60 fps and supported high-speed modes.
- Test camera zoom at both ends of the reported range, torch on/off and available H.264 encoders. Confirm zoom and torch change on the running picture with the phone still locked and dark, other setting changes restart capture, a camera change resets lens-specific controls, and different phones keep separate settings.
- With two phones set up, confirm the service uses whichever is plugged in, prefers the one set up last when both are, refuses a phone that was never set up, and keeps a running call on its phone.
- Test USB disconnect/reconnect, multiple consumers, camera-app crashes and a longer session.
- Test the notarized DMG on a clean Apple Silicon Mac, leaving quarantine intact.
- Record additional Android devices before expanding compatibility claims; Intel, iPhone and UVC paths remain unverified here.

Never commit phone serials, private frames or raw device logs. See [hardware acceptance](ACCEPTANCE.md) for additional test procedures.
