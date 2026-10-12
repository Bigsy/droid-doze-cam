#!/usr/bin/env python3
"""Assemble native app/system-extension metadata. No signing secrets are generated."""
import argparse
import pathlib
import plistlib
import re
import shutil


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(value, handle, sort_keys=True)


def assemble(output, binary_dir, team, bundle_id, build_number):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("TEAM_ID must contain exactly 10 uppercase letters/digits")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise ValueError("BUNDLE_ID must be a reverse-DNS identifier")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build_number):
        raise ValueError("BUILD_NUMBER must have one to three numeric components")
    app = output / "DroidDozeCam.app"
    if app.exists():
        raise FileExistsError(f"Refusing to merge into an existing app: {app}")
    ext_id = bundle_id + ".camera"
    group = team + "." + bundle_id
    extension = app / "Contents/Library/SystemExtensions" / (ext_id + ".systemextension")
    common = {"CFBundleDevelopmentRegion": "en", "CFBundleInfoDictionaryVersion": "6.0",
              "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": build_number,
              "LSMinimumSystemVersion": "13.0", "NSHumanReadableCopyright": "Copyright 2026 PhoneCam contributors and DroidDozeCam contributors"}
    host_info = dict(common, CFBundleIdentifier=bundle_id, CFBundleName="DroidDozeCam", CFBundleDisplayName="DroidDozeCam",
                     CFBundleExecutable="phonecam", CFBundlePackageType="APPL", CFBundleIconFile="PhoneCam.icns", LSUIElement=True,
                     PhoneCamAppGroup=group,
                     NSCameraUsageDescription="DroidDozeCam uses your connected phone camera and passes video to your Mac camera applications.",
                     NSCameraUseContinuityCameraDeviceType=True,
                     NSSystemExtensionUsageDescription="DroidDozeCam installs a virtual camera so applications can use your USB phone video.")
    ext_info = dict(common, CFBundleIdentifier=ext_id, CFBundleName="DroidDozeCam Camera", CFBundleDisplayName="DroidDozeCam",
                    CFBundleExecutable="PhoneCamCameraExtension", CFBundlePackageType="SYSX",
                    PhoneCamAppGroup=group,
                    CMIOExtension={"CMIOExtensionMachServiceName": group},
                    NSSystemExtensionUsageDescription="Expose phone video as DroidDozeCam.",
                    PhoneCamHostBundleIdentifier=bundle_id, PhoneCamTeamIdentifier=team)
    for bundle, info, executable in [(app, host_info, "phonecam"), (extension, ext_info, "PhoneCamCameraExtension")]:
        write_plist(bundle / "Contents/Info.plist", info)
        destination = bundle / "Contents/MacOS" / executable
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary_dir / executable, destination)
        destination.chmod(0o755)
        (bundle / "Contents/PkgInfo").write_bytes(info["CFBundlePackageType"].encode() + b"????")
    (app / "Contents/Resources").mkdir(parents=True, exist_ok=True)
    icon = pathlib.Path(__file__).resolve().parent.parent / "assets/PhoneCam.icns"
    shutil.copy2(icon, app / "Contents/Resources/PhoneCam.icns")
    entitlement_base = {"com.apple.developer.team-identifier": team, "com.apple.security.application-groups": [group]}
    host_entitlements = dict(entitlement_base, **{
        "com.apple.application-identifier": team + "." + bundle_id,
        "com.apple.developer.system-extension.install": True,
        "com.apple.security.device.camera": True})
    ext_entitlements = dict(entitlement_base, **{
        "com.apple.application-identifier": team + "." + ext_id,
        "com.apple.security.app-sandbox": True})
    write_plist(output / "Host.entitlements", host_entitlements)
    write_plist(output / "Camera.entitlements", ext_entitlements)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--binaries", required=True, type=pathlib.Path)
    parser.add_argument("--team", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-number", default="1")
    args = parser.parse_args()
    try:
        print(assemble(args.output, args.binaries, args.team, args.bundle_id, args.build_number))
    except (ValueError, OSError) as error:
        parser.error(str(error))
