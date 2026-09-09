# Verification record

Recorded on 2026-09-09. PhoneCam is a developer preview. Device capability, observed image quality, an ad-hoc build and a signed virtual-camera installation are separate validation results.

## Physical Android camera path

Environment: Apple Silicon Mac, macOS 26.6.2, Swift 6.3.1 / macOS SDK 26.4; Android model 25098PN5AC, API 37; official pinned scrcpy-server 3.3.4; OBS 32.2.2 with its existing system camera extension enabled.

Pipeline: **Android USB → VideoToolbox hardware H.264 decode → Core Image / Metal → Syphon → OBS Virtual Camera → browser getUserMedia**.

| Check | Observation |
|---|---|
| PhoneCam capture | 80.35 seconds, 2,367 input frames, 2,197 processed frames, 169 latest-frame replacements, zero reported queue drops; average input 29.46fps |
| Native preview | 2,140 displayed frames; actual room/desk content, hand occlusion and focus changes observed |
| Independent browser | Selected device was OBS Virtual Camera; 1920×1080 / requested 30fps, no audio |
| Browser live-image interval | 1,837 presentation callbacks over 68.12 seconds: 26.97fps average; 313 pixel samples with non-black spatial detail and 312 changes |
| Image orientation | Native and browser images compared; top/bottom and left/right matched after fixing Syphon texture orientation |
| Normal stop | Closing the preview produced black output in the independent receiver; subsequent pixel samples stayed black |
| Restart | OBS rediscovered the same named source and the browser recovered without reselecting the input |
| Cleanup | No capture process, session ADB forwarding or temporary phonecam server jar remained |

PhoneCam's source/processed resolution was **1280×720**. OBS fitted it to a 1920×1080 canvas, so the consumer's dimensions do not establish native 1080p source detail. Browser counts measure presentation callbacks, not USB arrival or end-to-end latency. This is not a constant-30fps performance guarantee or a multi-model compatibility claim.

Earlier local capture tests also exercised native 1080p processing, rotation, mirroring, cropping and SIGINT. No camera images, video, device serials or machine-specific raw logs are published here.

## Automated coverage

The baseline public preview has 34 Swift core/media tests, 4 bundle/tooling tests and 10 CLI integration checks. CI publishes current results for the exact public commit:

[Build and tests](https://github.com/wybaby168/phonecam/actions/workflows/ci.yml)

The icon is included by the bundle builder; the bundle test checks both the `CFBundleIconFile` reference and the copied ICNS contents. CI artifacts are ad-hoc development builds, not notarized installers.

## Open validation gates

- Physical iPhone Continuity Camera and Android UVC devices.
- More Android models/firmware, physical cable reconnects, multiple consumers and one-hour stability.
- Individual receiving applications and their camera-selection policies.
- Project-owned signing/profiles, notarization and real independent-consumer validation for **PhoneCam USB Camera**, the project's own extension.
- Homebrew installation and public signed distribution.

The local `install-extension` attempt failed with a missing `com.apple.developer.system-extension.install` entitlement. The verified OBS path uses OBS's existing extension; it does not establish that PhoneCam's extension works.

See [ACCEPTANCE.md](ACCEPTANCE.md) for a repeatable test procedure and submit new devices using the compatibility issue template.
