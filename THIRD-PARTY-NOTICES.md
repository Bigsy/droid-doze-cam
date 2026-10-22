# Third-party components and references

## Upstream source attribution

DroidDozeCam derives from [PhoneCam](https://github.com/wybaby168/phonecam).
Copyright (c) 2026 PhoneCam contributors. The original MIT copyright and permission notice is retained in [LICENSE](LICENSE) and included in distributed app bundles.


## scrcpy-server

Project: Genymobile/scrcpy
Pinned version: 5.0.1
Release: https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1
Upstream license: Apache License 2.0
Copyright: Genymobile and scrcpy contributors; see the upstream source notices.
License text: https://github.com/Genymobile/scrcpy/blob/v5.0.1/LICENSE

This repository does not include the scrcpy server binary or copy its Java implementation. The public release script downloads the official release asset, verifies its SHA-256, and bundles it with the matching Apache-2.0 license in the signed app. Source builds can still use the optional setup script to download it separately. The expected server hash is:

`764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`

The Swift receiver implements the documented, version-pinned binary protocol. The release app includes `scrcpy-LICENSE.txt` and this notice. The MIT license on DroidDozeCam does not relicense scrcpy.

## Android Platform-Tools / ADB (user download)

The release app can download official Android SDK Platform-Tools 37.0.1 from Google after the user accepts Google's SDK terms. It verifies the pinned archive hash, extracts the package into that user's Application Support folder, and retains Google's `NOTICE.txt`. The user can also select an existing installation or use a distribution such as Homebrew's android-platform-tools cask. The release ZIP does not bundle or relicense Google's Platform-Tools binaries.

Official distribution: https://developer.android.com/tools/releases/platform-tools
Homebrew cask: https://formulae.brew.sh/cask/android-platform-tools

## Apple frameworks and SDK

AVFoundation, CoreMediaIO, CoreMedia, CoreVideo, VideoToolbox, CoreImage, Metal, IOSurface, AppKit, Security, SystemExtensions and IOKit are Apple system frameworks. They are linked, not distributed by this source archive. Use Xcode/macOS SDK under Apple's applicable agreements.

## API implementation references

Apple's Camera Extension documentation and Genymobile's protocol source were consulted. Laurent Denoue's public MIT-licensed cameraextension example was also consulted to verify CMIO source/sink calling conventions:

https://github.com/ldenoue/cameraextension

The project's framing, stream state, buffer management, renderer, CLI, USB transport, authorization, build scripts and tests are implemented in this repository. This project is not affiliated with or endorsed by Apple, Google, Genymobile or the example's author.

## Syphon / OBS (optional, separately installed)

`preview --syphon` and `probe --syphon` dynamically load an existing official Syphon Metal framework, including the framework shipped in OBS. DroidDozeCam contains an adapter using public Objective-C method signatures; no Syphon implementation, framework binary or OBS binary is copied into this source or app package.

- Syphon project and public API: https://github.com/Syphon/Syphon-Framework
- Syphon license: BSD-2-Clause; see upstream source notices and license: https://github.com/Syphon/Syphon-Framework/blob/main/SyphonMetalServer.h
- OBS virtual camera guide: https://obsproject.com/kb/virtual-camera-guide

This local integration was tested with OBS 32.2.2 and an ad-hoc upstream build. Redistribution or rebundling of those third-party components would require their notices and applicable license obligations; the repository’s MIT license does not relicense them. Hardened-runtime signed distributions need a separately validated framework loading/signing strategy.
