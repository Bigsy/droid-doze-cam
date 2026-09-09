# Roadmap

This is a list of product and verification priorities, not a release schedule.

## Current developer preview

- Android USB capture, hardware decode checks and local image processing.
- Native preview and an optional OBS/Syphon output path.
- Physical Android-to-browser camera validation on Apple Silicon.
- Open source, reproducible builds, CI and compatibility-report templates.

## Next priorities

1. **Broader device evidence:** iPhone Continuity Camera, Android UVC, more Android firmware, physical disconnect/reconnect, receiving apps and one-hour sessions.
2. **Standalone output:** project-owned Developer ID signing/profiles, notarization and end-to-end validation of the PhoneCam camera extension.
3. **Distribution:** a signed release and a validated Homebrew Cask, with documented installation and uninstall behavior.
4. **Usability:** improve setup diagnostics and device selection from real issue reports.

Windows is outside the current product scope. Its implementation needs native backends rather than a cross-compile flag; see [PLATFORMS.md](PLATFORMS.md). A future proposal should include a Windows hardware validation plan and an iPhone input strategy.
