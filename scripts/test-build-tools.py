#!/usr/bin/env python3
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import sparkle_updates

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
            self.assertEqual(host["SUPublicEDKey"], sparkle_updates.PUBLIC_KEY)
            self.assertEqual(host["SUFeedURL"], sparkle_updates.FEED_URL)
            self.assertFalse(host["SUEnableAutomaticChecks"])
            self.assertFalse(host["SUAllowsAutomaticUpdates"])
            self.assertTrue(host["SURequireSignedFeed"])
            self.assertTrue(host["SUVerifyUpdateBeforeExtraction"])
            self.assertNotIn("SUPublicEDKey", extension)

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

class UpdateTests(unittest.TestCase):
    def info(self):
        return dict(SUPublicEDKey=sparkle_updates.PUBLIC_KEY, SUFeedURL=sparkle_updates.FEED_URL,
                    CFBundleVersion="20261113180000", CFBundleShortVersionString="0.1.0")

    def test_rejects_incomplete_or_invalid_update_configuration(self):
        self.assertFalse(sparkle_updates.validate_configuration({}))
        cases = dict(SUPublicEDKey=["", "invalid", "eA=="],
                     SUFeedURL=["", "http://example.com/feed.xml", "https://user:pass@example.com/feed.xml",
                                "https://example.com/feed.xml?token=secret", "https://example.com/releases"],
                     CFBundleVersion=["0", "-1", "1.2.3.4", "beta"])
        for field, values in cases.items():
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    sparkle_updates.validate_configuration({**self.info(), field: value})

    def test_fork_overrides_require_own_key_and_feed(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist = pathlib.Path(temporary) / "Info.plist"
            plist.write_bytes(plistlib.dumps(self.info()))
            with self.assertRaises(ValueError):
                sparkle_updates.configure(plist, {"SPARKLE_FEED_URL": "https://example.com/appcast.xml"})
            sparkle_updates.configure(plist, dict(SPARKLE_PUBLIC_ED_KEY=sparkle_updates.PUBLIC_KEY,
                                                  SPARKLE_FEED_URL="https://example.com/appcast.xml"))
            self.assertEqual(plistlib.loads(plist.read_bytes())["SUFeedURL"], "https://example.com/appcast.xml")

    def test_mismatched_key_rejected_without_exporting_private_key(self):
        with patch.object(sparkle_updates, "run", return_value="wrong-public-key") as run:
            with self.assertRaises(ValueError): sparkle_updates.verify_signing_key(self.info(), "fixture")
            self.assertEqual(run.call_args.args[1:], ("--account", "fixture", "-p"))

    def test_generation_checks_exact_archive_and_verifies_signed_feed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            dmg = root / "DroidDozeCam-macos-arm64.dmg"
            dmg.write_bytes(b"archive fixture")
            (root / "unrelated.zip").write_bytes(b"must not be offered")
            feed = root / "appcast.xml"
            prefix = "https://github.com/Bigsy/droid-doze-cam/releases/download/v0.1.0/"
            for bad_url, bad_size, bad_build, unsigned in [(True, False, False, False), (False, True, False, False),
                                                          (False, False, True, False), (False, False, False, True),
                                                          (False, False, False, False)]:
                def run(*args):
                    if pathlib.Path(args[0]).name == "generate_appcast":
                        self.assertEqual([p.name for p in pathlib.Path(args[-1]).iterdir()], [dmg.name])
                        feed.write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                            f'<sparkle:version>{"1" if bad_build else self.info()["CFBundleVersion"]}</sparkle:version>'
                            f'<enclosure url="{prefix + ("wrong.dmg" if bad_url else dmg.name)}" '
                            f'length="{0 if bad_size else dmg.stat().st_size}" '
                            f'sparkle:edSignature="{"" if unsigned else "signature"}"/></item></channel></rss>')
                with patch.object(sparkle_updates, "verify_signing_key"), patch.object(sparkle_updates, "run", side_effect=run) as command:
                    if any([bad_url, bad_size, bad_build, unsigned]):
                        with self.assertRaises(ValueError):
                            sparkle_updates.generate_appcast(dmg, feed, self.info(), "0.1.0", "fixture")
                    else:
                        sparkle_updates.generate_appcast(dmg, feed, self.info(), "0.1.0", "fixture")
                        self.assertEqual(command.call_args.args[1:], ("--account", "fixture", "--verify", feed))
                feed.unlink()

    def test_older_or_reused_builds_and_public_versions_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "appcast.xml").write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                '<sparkle:version>20</sparkle:version><sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>'
                '</item></channel></rss>')
            with patch.object(sparkle_updates, "ROOT", root), patch.object(sparkle_updates, "verify_signing_key"):
                for build, version in [("19", "0.1.1"), ("20", "0.1.1"), ("21", "0.1.0")]:
                    with self.assertRaises(ValueError):
                        sparkle_updates.generate_appcast(root / "app.dmg", root / "new.xml",
                            {**self.info(), "CFBundleVersion": build}, version, "fixture")

if __name__ == "__main__": unittest.main(verbosity=2)
