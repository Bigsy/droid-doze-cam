# Changelog

User-facing changes are recorded here. The initial public repository is a developer preview; a signed stable binary is not available yet.

## Unreleased

### Added

- Native live preview controlled by `phonecam preview`.
- Optional Syphon Metal output for an existing OBS installation.
- Android USB H.264 capture with pinned scrcpy-server 3.3.4, hardware decoder checks and bounded frame processing.
- iPhone Continuity Camera and UVC capture backends, pending physical-device reports.
- A macOS app icon, bilingual README, contributor guide and issue templates.
- Linux core and macOS build/test CI; documented Windows feasibility assessment.

### Fixed

- macOS Swift/framework compile errors and CF object ownership.
- Installer command-path selection and preservation of the previous app.
- Syphon server discovery on the main run loop and vertical texture orientation in OBS.

### Verified

- Physical Android → native preview → OBS Virtual Camera → independent browser, including motion, orientation, normal stop to black and producer restart recovery.

### Pending

- Signed/notarized standalone PhoneCam camera extension, broader device/app coverage and Homebrew distribution.
