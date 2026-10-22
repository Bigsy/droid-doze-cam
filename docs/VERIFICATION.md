# Verification status

The current source is a developer preview. Syntax checks and a source review are not a substitute for building, signing and testing the app on real hardware.

## Recorded device coverage

Earlier DroidDozeCam builds were reported working with a Samsung Galaxy S23 Ultra and an Apple Silicon Mac, using Photo Booth and Google Meet in Chrome. Opening the camera started USB capture, closing it stopped capture, and the phone remained locked with its screen off. These observations do not validate every Android device or the latest source changes.

The upstream project separately recorded Android → native preview → Syphon → OBS Virtual Camera → browser testing. That validates an earlier OBS route, not this fork's current system camera extension. Upstream attribution is in [third-party notices](../THIRD-PARTY-NOTICES.md).

## Current source review

The public cleanup includes module/executable renaming, stricter producer authentication, reduced duplicate startup checks, test-pattern support and updated camera status reporting. It also migrates to scrcpy 5.0.1, handles the new codec/session/packet headers, discovers camera modes and encoders, and adds per-phone source size, zoom, torch and encoder controls. Local checks on 24 October 2026 passed: the signed arm64 build, 57 core tests, 10 media tests, 5 bundle-tooling checks and 10 CLI integration checks. A development-signed camera extension was activated and appeared in the Mac camera list. A short USB probe with the connected Samsung SM_S938B discovered camera modes and H.264 encoders, and captured video through scrcpy 5.0.1 using hardware decoding.

The release app and DMG are Developer ID signed, notarized by Apple and stapled. The DMG is mounted read-only during packaging to verify its embedded app and Applications shortcut. Fresh-Mac installation, end-to-end video calls with the distribution build, locked-screen regression checks and longer hardware sessions remain pending; the release is a prerelease.

`./scripts/test.sh` runs the Swift tests, bundle-tooling checks, syntax checks, an unsigned app build and CLI integration checks. It does not install or activate a camera extension. Builds and tests run locally; this repository has no hosted CI.

The lease-file CLI test checks on-demand dispatch and termination. Actual test-pattern delivery through the camera extension must be checked with a correctly signed app. The signature tests reject platform and ad-hoc code; acceptance of the signed host still needs installation testing on supported macOS versions.

## Before distributing a new binary

- Run the full local test suite and verify the signed host and extension work together.
- Confirm upgrades from an earlier build preserve the login service, phone selection and camera approval.
- Check live blur strength, capture settings, frame rate and immediate stop behavior.
- Confirm scrcpy 5.0.1 starts with the phone already locked and screen off, and recovers after USB reconnect and encoder/session resets.
- Compare `droiddozecam cameras --json` with the phone's actual capture modes. Test Automatic and explicit source sizes, 30/60 fps and supported high-speed modes.
- Test camera zoom at both ends of the reported range, torch on/off and available H.264 encoders. Confirm setting changes restart capture, a camera change resets lens-specific controls, and different phones keep separate settings.
- Test USB disconnect/reconnect, multiple consumers, camera-app crashes and a longer session.
- Test the notarized DMG on a clean Apple Silicon Mac, leaving quarantine intact.
- Record additional Android devices before expanding compatibility claims; Intel, iPhone and UVC paths remain unverified here.

Never commit phone serials, private frames or raw device logs. See [hardware acceptance](ACCEPTANCE.md) for additional test procedures.
