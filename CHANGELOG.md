# Changelog

User-facing changes are recorded here. The initial release is a developer preview, distributed as a signed and notarized Apple Silicon DMG.

## DroidDozeCam fork

### Release packaging

- Publish a Developer ID signed, notarized and stapled DMG with an Applications shortcut and SHA-256 checksum.
- Keep builds and notarization on the signing Mac; no hosted workflows.

### Public repository cleanup

- Simplified English setup instructions, emphasizing no phone app and locked, screen-off capture; removed the Chinese README.
- Require an Apple Development or Developer ID certificate category for the camera frame producer.
- Avoid resolving capture settings and checking the Android version repeatedly at startup; keep reconnect device checks and server checksum verification.
- Add `serve --source test` for on-demand testing with a signed camera extension.
- Report a missing camera extension in the service log and menu status while retaining automatic recovery.
- Rename source modules, binaries, assets and app text consistently to DroidDozeCam; preserve upstream notices in distributed bundles. Keep immediate capture shutdown and the current blur strength slider.


### scrcpy integration

- Pin the official scrcpy 5.0.1 server and license with updated SHA-256 checksums.
- Parse the new stream/session headers and packet flags; reset the decoder and timing when a new session begins.
- Discover camera source sizes, frame rates, zoom ranges and H.264 encoders in Settings and the new `cameras` CLI command.
- Add per-phone source size, camera zoom, torch and encoder settings. Phone controls restart capture; camera zoom applies on slider release. Keep live Mac crop and blur separate.
- Match automatic source aspect ratio to the selected output, including 4:3 VGA.
- Local builds, automated checks and a short USB capture probe passed; full device validation is tracked in `docs/VERIFICATION.md`.

### Added

- Smooth phone zoom slider with an editable live readout, shorter Capture guidance, and a compact Setup checklist with grouped actions.

- On-demand `serve` login service: USB capture starts when a Mac app opens the DroidDozeCam camera and stops when it closes, with the phone kept locked and dark.
- Menu bar settings app with Capture, Image and Setup tabs, per-phone camera choices, zoom, background blur with a strength slider and a checked ADB download.
- Menu bar status: ready, starting, streaming, reconnecting, or why the phone is unavailable while an app uses the camera.
- Signed and notarized Apple Silicon release script, `scripts/release.sh`.
- The phone sends 30 fps while the Mac app takes 30 fps or fewer, instead of a higher saved frame rate, which roughly halves the work for typical call apps.

### Fixed

- Background blur composites with Metal Performance Shaders instead of Core Image, so at 1080p60 it adds about 10% of one CPU core instead of about 23%.
- The service logs capture failures it detects itself, such as a stalled camera sink, instead of restarting silently.
- Camera choices made while the service's phone is unplugged, or with two phones attached, now apply to the service's phone.
- The ADB download progress bar moves.
- `install.sh` removes its backup of the previous app and quits the menu bar app itself.
- Opening DroidDozeCam.app while the service runs starts the menu bar app.
- Settings opens without waiting for the phone's camera list or the readiness checks.
- The camera extension stops the phone stream when a camera app exits without stopping its stream.
- When the camera stays missing, the service restarts at most once every 10 minutes; it also rotates its log at 5 MB.
- `build.sh` numbers each build with a timestamp by default, and always bundles the pinned scrcpy server; `install.sh` refuses a build without one.

### Removed

- GitHub Actions CI and release workflows, Dependabot, and issue and pull request templates. Builds, tests and releases run locally; `scripts/test.sh` builds its unsigned app outside `dist/`.
