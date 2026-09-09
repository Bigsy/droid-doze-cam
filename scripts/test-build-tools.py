#!/usr/bin/env python3
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("bundles", ROOT / "scripts/make-bundles.py")
bundles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundles)

class BundleTests(unittest.TestCase):
    def build(self, root):
        binary_dir = root / "bin"
        binary_dir.mkdir()
        for name in ("phonecam", "PhoneCamCameraExtension"):
            (binary_dir / name).write_bytes(b"TEST FIXTURE, NOT A MACH-O BINARY")
        return bundles.assemble(root / "dist", binary_dir, "A123456789", "dev.example.phonecam", "2.0.1")

    def test_bundle_layout_and_identifiers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp); app = self.build(root)
            ext = app / "Contents/Library/SystemExtensions/dev.example.phonecam.camera.systemextension"
            with (app / "Contents/Info.plist").open("rb") as f: host = plistlib.load(f)
            with (ext / "Contents/Info.plist").open("rb") as f: extension = plistlib.load(f)
            with (root / "dist/Host.entitlements").open("rb") as f: entitlements = plistlib.load(f)
            with (root / "dist/Camera.entitlements").open("rb") as f: camera_entitlements = plistlib.load(f)
            self.assertEqual(host["CFBundleIdentifier"], extension["PhoneCamHostBundleIdentifier"])
            self.assertEqual(extension["CMIOExtension"]["CMIOExtensionMachServiceName"], entitlements["com.apple.security.application-groups"][0])
            self.assertEqual(entitlements["com.apple.security.application-groups"], camera_entitlements["com.apple.security.application-groups"])
            self.assertTrue(entitlements["com.apple.developer.system-extension.install"])
            self.assertTrue(camera_entitlements["com.apple.security.app-sandbox"])
            self.assertNotIn("com.apple.security.app-sandbox", entitlements)
            self.assertTrue((app / "Contents/MacOS/phonecam").is_file())
            self.assertTrue((ext / "Contents/MacOS/PhoneCamCameraExtension").is_file())
            icon = app / "Contents/Resources" / host["CFBundleIconFile"]
            self.assertEqual(icon.read_bytes(), (ROOT / "assets/PhoneCam.icns").read_bytes())
            self.assertEqual(icon.read_bytes()[:4], b"icns")

    def test_invalid_identifiers_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            p = pathlib.Path(temp)
            for team, identifier in [("BAD", "dev.example.pc"), ("A123456789", 'dev.example."bad'), ("A123456789", "../../bad")]:
                with self.assertRaises(ValueError): bundles.assemble(p / "out", p, team, identifier, "1")

    def test_refuses_merge_into_existing_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            p = pathlib.Path(temp); self.build(p)
            with self.assertRaises(FileExistsError): bundles.assemble(p / "dist", p / "bin", "A123456789", "dev.example.phonecam", "1")

    def test_version_pin_matches_setup_script(self):
        core = (ROOT / "Sources/PhoneCamCore/Configuration.swift").read_text()
        setup = (ROOT / "scripts/setup-android.sh").read_text()
        import re
        for swift, shell in [(r'scrcpyVersion = "([^"]+)"', r'^VERSION=(.+)$'), (r'scrcpySHA256 = "([^"]+)"', r'^SHA256=(.+)$')]:
            self.assertEqual(re.search(swift, core).group(1), re.search(shell, setup, re.M).group(1))

if __name__ == "__main__": unittest.main(verbosity=2)
