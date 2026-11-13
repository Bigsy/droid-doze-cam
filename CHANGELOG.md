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
- Add per-phone source size, camera zoom, torch and encoder settings. Camera, source size and encoder changes restart capture; camera zoom applies on slider release. Keep live Mac crop and blur separate.
- Match automatic source aspect ratio to the selected output, including 4:3 VGA.
- Local builds, automated checks and a short USB capture probe passed; full device validation is tracked in `docs/VERIFICATION.md`.

### Added

- Phone zoom and torch change on the running picture instead of restarting capture, through the scrcpy control channel. The picture zooms in steps of about 6%, so it can be up to about 3% off the chosen ratio until capture next starts. If the channel gives no video, that capture starts without it; once this happens twice in a row on a phone, its captures skip the channel and these settings restart capture as before. A single failure, such as a phone restarting for a system update, does not turn the channel off. Checked on one phone: it stayed asleep and locked through a short capture, and torch changes were seen on a running capture in the signed app.
- The login service follows the phones chosen in Set Up Camera: it uses whichever is plugged in, the one set up last when several are, each with its own camera choices. A phone that was never set up is not used, and Set Up Camera refuses a device with no usable camera. When no set-up phone is plugged in, the Setup checklist says so, rather than offering to set up another device that is, such as a tablet. A service installed by an earlier build keeps its single phone until Set Up Camera runs again. The choice of phone was checked with two devices attached; switching between two phones with cameras has not been checked.
- Menu bar items for mirroring, background blur, torch and switching between the front and back camera, and a phone zoom slider in the menu.
- `droiddozecam install-extension` refuses to replace a camera extension whose process is still running, which could leave Mac apps without the camera until a newer build or a restart; `--force` replaces it regardless. `install.sh` says how to free a running extension, and after replacing one it waits until Mac apps can see the camera before the login service restarts.
- **Show preview** tick box in Settings: a live picture of what Mac apps receive, above the tabs, for judging rotation, mirroring, crop, blur and zoom without opening another app. The phone camera runs while it is ticked, and it is unticked each time Settings opens. Opening it while another app is in a call has not been checked.
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
- The camera extension sends a phone frame that follows the previous one too closely after a short wait, instead of skipping it and leaving a gap of two frames. Not yet checked with a signed extension and a phone.
- The service log has the time on each line and the app version and build at startup. It writes a progress line once a minute instead of every two seconds, and the frame counts when a capture stops.
- Settings → Setup shows the app as installed wherever setup accepts it: renamed, or in a subfolder of Applications.
- Capture starts slightly sooner: adb commands return as soon as they exit, the phone's model is not looked up twice, and the camera server is retried every 0.1 seconds.
- Background blur is set up for the first blurred frame, not for every capture, the camera extension and the preview window.
- The architecture and acceptance documents are in English, with the current camera name and the log subsystem the extension uses.
- `serve --demand-dir` keeps its status beside its demand file, so the CLI tests no longer replace the login service's menu bar status.

### Removed

- GitHub Actions CI and release workflows, Dependabot, and issue and pull request templates. Builds, tests and releases run locally; `scripts/test.sh` builds its unsigned app outside `dist/`.
