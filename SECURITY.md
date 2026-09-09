# Security and privacy

PhoneCam captures video locally. The Android path uses authorized USB ADB and rejects wireless ADB device selection. Video processing occurs on the Mac; the optional Syphon path exposes frames to local Syphon clients such as OBS. Treat other software running under your account as part of the local trust boundary.

PhoneCam itself does not record video, upload it, create a microphone device or start at login. Receiving applications control what they record or transmit. The normal stop path clears output and cleans up the ADB forwarding and temporary server created by this session. A forced process kill cannot guarantee cleanup; see [troubleshooting](docs/ACCEPTANCE.md).

The Android setup script verifies the pinned server checksum. Keep that check intact. Use the normal macOS camera and system-extension approval mechanisms. Do not disable SIP, Gatekeeper or privacy checks to make a development build appear installable.

## Report a vulnerability

Use GitHub's **Security → Report a vulnerability** on [this repository](https://github.com/wybaby168/phonecam/security/advisories/new) for sensitive findings. Do not include exploit details, private camera frames, device serials or credentials in a public issue.

This is a volunteer-maintained developer preview. There is no promised response SLA or maintained stable release branch yet. Include the affected commit, a minimal reproduction, impact and any mitigation you have verified.
