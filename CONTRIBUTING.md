# Contributing to PhoneCam

Start with a reproducible problem, a device compatibility report, or a focused improvement. The project is a macOS developer preview; a successful compile is not a claim that a phone, meeting app or signed camera extension works.

## Local workflow

Use macOS 13+, Xcode 15+ / Swift 5.9+, and Python 3.

```bash
git clone https://github.com/wybaby168/phonecam.git
cd phonecam
./scripts/test.sh
```

This runs Swift core/media tests, bundle checks, shell/Swift syntax checks, a release build, and CLI integration checks with a synthetic source. It does not ask for a real camera or install a system extension. On Linux, `swift test` covers `PhoneCamCore` only.

For a real phone, build/install as described in the README, then use `preview` and an independent camera consumer. Close the capture window when done. [Hardware acceptance steps](docs/ACCEPTANCE.md)

## Changes and review

- Keep capture, rendering, output and UI responsibilities in their existing modules; fix shared behavior rather than matching one phone model or sample image.
- Keep frames bounded and timestamps monotonic. Handle cancellation, stale input and resource cleanup explicitly.
- Validate the affected behavior. Media/protocol changes need meaningful regression coverage; device or output changes also need visual hardware evidence.
- Explain the trigger, resulting behavior, tests and remaining limitations in the pull request.
- Update both README languages when user-facing behavior or setup changes. Keep the compatibility and verification records accurate.
- Never commit phone serial numbers, private frames, provisioning profiles, certificates, private keys, tokens or unredacted device reports. Local logs belong in ignored `artifacts/`.

## Device reports

Include phone model and OS, Mac model/architecture and macOS, command/options with serials removed, source type, actual encoded/processed dimensions, receiving application/version, and whether image content, orientation, stopping and recovery were checked. Mark untested fields as untested. App/device coverage grows only from recorded evidence.

## App icon

`assets/phonecam.png` is the 1024px source. After replacing it, regenerate the checked-in ICNS on macOS:

```bash
./scripts/make-icon.sh
```

The bundle builder copies the ICNS and sets `CFBundleIconFile`; bundle tests verify the resource mapping. The [asset notes](assets/README.md) record the original design brief.

## Versioning and releases

Use semantic versioning for published releases. Version `1.0.0` currently identifies the imported developer-preview source; no stable signed release is advertised.

When changing versions, keep `Constants.version` in `Configuration.swift`, the bundle version in `scripts/make-bundles.py`, and `scripts/test-cli.py` consistent. `BUILD_NUMBER` is the independent macOS bundle build counter.

A release candidate needs a clean commit, CI, local install verification and a compatibility report. Publishing a standalone PhoneCam camera requires valid signing/profiles, notarization and a real independent consumer test. CI artifacts are ad-hoc development builds. See [SIGNING.md](docs/SIGNING.md) and the [roadmap](docs/ROADMAP.md).
