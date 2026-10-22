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
        for name in ("droiddozecam", "DroidDozeCamCameraExtension"):
            (binary_dir / name).write_bytes(b"TEST FIXTURE, NOT A MACH-O BINARY")
        return bundles.assemble(root / "dist", binary_dir, "A123456789", "dev.example.droiddozecam", "2.0.1")

    def test_bundle_layout_and_identifiers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp); app = self.build(root)
            ext = app / "Contents/Library/SystemExtensions/dev.example.droiddozecam.camera.systemextension"
            with (app / "Contents/Info.plist").open("rb") as f: host = plistlib.load(f)
            with (ext / "Contents/Info.plist").open("rb") as f: extension = plistlib.load(f)
            with (root / "dist/Host.entitlements").open("rb") as f: entitlements = plistlib.load(f)
            with (root / "dist/Camera.entitlements").open("rb") as f: camera_entitlements = plistlib.load(f)
            self.assertEqual(host["CFBundleIdentifier"], extension["DroidDozeCamHostBundleIdentifier"])
            self.assertEqual(host["CFBundleExecutable"], "droiddozecam")
            self.assertEqual(extension["CFBundleExecutable"], "DroidDozeCamCameraExtension")
            for bundle in (app, ext):
                self.assertEqual((bundle / "Contents/Resources/LICENSE.txt").read_bytes(), (ROOT / "LICENSE").read_bytes())
                self.assertEqual((bundle / "Contents/Resources/THIRD-PARTY-NOTICES.md").read_bytes(), (ROOT / "THIRD-PARTY-NOTICES.md").read_bytes())
            self.assertEqual(extension["CMIOExtension"]["CMIOExtensionMachServiceName"], entitlements["com.apple.security.application-groups"][0])
            self.assertEqual(entitlements["com.apple.security.application-groups"], camera_entitlements["com.apple.security.application-groups"])
            self.assertTrue(entitlements["com.apple.developer.system-extension.install"])
            self.assertTrue(camera_entitlements["com.apple.security.app-sandbox"])
            self.assertNotIn("com.apple.security.app-sandbox", entitlements)
            self.assertTrue((app / "Contents/MacOS/droiddozecam").is_file())
            self.assertTrue((ext / "Contents/MacOS/DroidDozeCamCameraExtension").is_file())
            icon = app / "Contents/Resources" / host["CFBundleIconFile"]
            self.assertEqual(icon.read_bytes(), (ROOT / "assets/DroidDozeCam.icns").read_bytes())
            self.assertEqual(icon.read_bytes()[:4], b"icns")

    def test_invalid_identifiers_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            p = pathlib.Path(temp)
            for team, identifier in [("BAD", "dev.example.pc"), ("A123456789", 'dev.example."bad'), ("A123456789", "../../bad")]:
                with self.assertRaises(ValueError): bundles.assemble(p / "out", p, team, identifier, "1")

    def test_refuses_merge_into_existing_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            p = pathlib.Path(temp); self.build(p)
            with self.assertRaises(FileExistsError): bundles.assemble(p / "dist", p / "bin", "A123456789", "dev.example.droiddozecam", "1")

    def test_version_pin_matches_setup_script(self):
        core = (ROOT / "Sources/DroidDozeCamCore/Configuration.swift").read_text()
        setup = (ROOT / "scripts/setup-android.sh").read_text()
        import re
        for swift, shell in [(r'scrcpyVersion = "([^"]+)"', r'^VERSION=(.+)$'), (r'scrcpySHA256 = "([^"]+)"', r'^SHA256=(.+)$')]:
            self.assertEqual(re.search(swift, core).group(1), re.search(shell, setup, re.M).group(1))
        version = re.search(r'scrcpyVersion = "([^"]+)"', core).group(1)
        digest = re.search(r'scrcpySHA256 = "([^"]+)"', core).group(1)
        self.assertEqual(version, bundles.SCRCPY_VERSION)
        self.assertEqual(digest, bundles.SCRCPY_SHA256)
        build = (ROOT / "scripts/build.sh").read_text()
        self.assertEqual(re.search(r'^SCRCPY_VERSION=(.+)$', build, re.M).group(1), version)
        install = (ROOT / "scripts/install.sh").read_text()
        self.assertEqual(re.search(r'^SCRCPY_SERVER_NAME=scrcpy-server-v(.+)$', install, re.M).group(1), version)
        release = (ROOT / "scripts/release.sh").read_text()
        self.assertIn(f"/v{version}/scrcpy-server-v{version}", release)
        self.assertIn(f"/v{version}/LICENSE", release)
        self.assertIn(digest, release)
        self.assertIn(bundles.SCRCPY_LICENSE_SHA256, release)

    def test_checked_copy_refuses_corrupt_artifact(self):
        import hashlib
        with tempfile.TemporaryDirectory() as temp:
            source, destination = pathlib.Path(temp) / "source", pathlib.Path(temp) / "copy"
            source.write_bytes(b"official fixture")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            bundles.checked_copy(source, destination, digest)
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            source.write_bytes(b"corrupt fixture")
            with self.assertRaises(ValueError): bundles.checked_copy(source, destination, digest)
            self.assertEqual(destination.read_bytes(), b"official fixture")

if __name__ == "__main__": unittest.main(verbosity=2)
