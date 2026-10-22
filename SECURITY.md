# Security and privacy

DroidDozeCam captures video locally. The Android path uses authorized USB ADB and rejects wireless ADB device selection. Video processing occurs on the Mac; the optional Syphon path exposes frames to local Syphon clients such as OBS. Treat other software running under your account as part of the local trust boundary.

DroidDozeCam does not record or upload camera video or create a microphone device. Its optional login service starts at login but captures only while a Mac app uses the camera. Receiving applications control what they record or transmit. The normal stop path clears output and cleans up the ADB forwarding and temporary server created by this session. A forced process kill cannot guarantee cleanup; see [troubleshooting](docs/ACCEPTANCE.md).

The release app includes a pinned scrcpy server with its checksum verified at build and runtime. If you choose **Download ADB…**, the app opens Google's license terms and downloads the pinned Platform-Tools archive from `dl.google.com` only after you agree. It verifies the archive checksum and ADB signature before installing the package under your user account. Camera frames are not sent to Google. Use the normal macOS camera and system-extension approval mechanisms. Do not disable SIP, Gatekeeper or privacy checks to make a development build appear installable.

## Report a vulnerability

Report sensitive findings privately to the maintainer. Do not include exploit details, private camera frames, device serials or credentials in anything public.

This is a volunteer-maintained developer preview. There is no promised response SLA or maintained stable release branch yet. Include the affected commit, a minimal reproduction, impact and any mitigation you have verified.
