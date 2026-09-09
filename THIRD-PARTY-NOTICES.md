# Third-party components and references

## scrcpy-server (external download, not bundled)

Project: Genymobile/scrcpy
Pinned version: 3.3.4
Release: https://github.com/Genymobile/scrcpy/releases/tag/v3.3.4
Upstream license: Apache License 2.0
Copyright: Genymobile and scrcpy contributors; see the upstream source notices.
License text: https://github.com/Genymobile/scrcpy/blob/v3.3.4/LICENSE

This repository does not include the scrcpy server binary or copy its Java implementation. The optional setup script downloads the official release asset and verifies this SHA-256:

`8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e`

The Swift receiver implements the documented, version-pinned binary protocol. If you redistribute the server along with your product, comply with Apache-2.0 and preserve applicable upstream license/NOTICE material; the MIT license on PhoneCam does not relicense scrcpy.

## Android Platform-Tools / ADB (separate installation)

The user installs official Android SDK Platform-Tools or a distribution such as Homebrew's android-platform-tools cask. Google's downloaded SDK package has its own terms. PhoneCam does not bundle, relicense, or replace those binaries.

Official distribution: https://developer.android.com/tools/releases/platform-tools
Homebrew cask: https://formulae.brew.sh/cask/android-platform-tools

## Apple frameworks and SDK

AVFoundation, CoreMediaIO, CoreMedia, CoreVideo, VideoToolbox, CoreImage, Metal, IOSurface, AppKit, Security, SystemExtensions and IOKit are Apple system frameworks. They are linked, not distributed by this source archive. Use Xcode/macOS SDK under Apple's applicable agreements.

## API implementation references

Apple's Camera Extension documentation and Genymobile's protocol source were consulted. Laurent Denoue's public MIT-licensed cameraextension example was also consulted to verify CMIO source/sink calling conventions:

https://github.com/ldenoue/cameraextension

PhoneCam's framing, stream state, buffer management, renderer, CLI, USB transport, authorization, build scripts and tests are implemented in this repository. This project is not affiliated with or endorsed by Apple, Google, Genymobile or the example's author.

## Syphon / OBS (optional, separately installed)

`preview --syphon` and `probe --syphon` dynamically load an existing official Syphon Metal framework, including the framework shipped in OBS. PhoneCam contains an adapter using public Objective-C method signatures; no Syphon implementation, framework binary or OBS binary is copied into this source or app package.

- Syphon project and public API: https://github.com/Syphon/Syphon-Framework
- Syphon license: BSD-2-Clause; see upstream source notices and license: https://github.com/Syphon/Syphon-Framework/blob/main/SyphonMetalServer.h
- OBS virtual camera guide: https://obsproject.com/kb/virtual-camera-guide

This local integration was tested with OBS 32.2.2 and an ad-hoc PhoneCam build. Redistribution or rebundling of those third-party components would require their notices and applicable license obligations; the PhoneCam MIT license does not relicense them. Hardened-runtime signed distributions need a separately validated framework loading/signing strategy.
