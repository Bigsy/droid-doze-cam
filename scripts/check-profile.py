#!/usr/bin/env python3
"""Check a security-cms-decoded provisioning profile before codesign."""
import argparse
import datetime
import fnmatch
import plistlib
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("profile")
parser.add_argument("entitlements")
parser.add_argument("--distribution", action="store_true", help="Reject development or device-limited profiles")
args = parser.parse_args()
with open(args.profile, "rb") as f:
    profile = plistlib.load(f)
with open(args.entitlements, "rb") as f:
    requested = plistlib.load(f)
errors = []
expiration = profile.get("ExpirationDate")
if not expiration or expiration <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    errors.append("Profile is expired or has no expiration date")
allowed = profile.get("Entitlements", {})
team = requested["com.apple.developer.team-identifier"]
if team not in profile.get("TeamIdentifier", []):
    errors.append("Team ID does not match")
for key in ["com.apple.application-identifier", "com.apple.developer.team-identifier"]:
    actual = allowed.get(key)
    if key == "com.apple.application-identifier" and actual is None:
        actual = allowed.get("application-identifier")
    if not isinstance(actual, str) or not fnmatch.fnmatchcase(requested[key], actual):
        errors.append(f"Profile does not authorize {key}={requested[key]}")
# Some macOS app-group entitlements are authorized by the Team-ID namespace, not a profile entry.
# When an explicit profile restriction is present, honor it.
for key in ["com.apple.security.application-groups"]:
    if key in allowed:
        for value in requested.get(key, []):
            if not any(fnmatch.fnmatchcase(value, item) for item in allowed[key]):
                errors.append(f"Profile does not authorize {key}={value}")
if "com.apple.developer.system-extension.install" in requested:
    if allowed.get("com.apple.developer.system-extension.install") is not True:
        errors.append("Host profile is missing the System Extension capability")
if args.distribution:
    if allowed.get("com.apple.security.get-task-allow", allowed.get("get-task-allow", False)):
        errors.append("Distribution profile permits debugging (get-task-allow)")
    if profile.get("ProvisionedDevices"):
        errors.append("Distribution profile is limited to registered devices")
    if profile.get("ProvisionsAllDevices") is not True or "OSX" not in profile.get("Platform", []):
        errors.append("Expected a Developer ID profile for all Macs")
if errors:
    print("Provisioning validation failed:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
print("Profile accepted:", profile.get("Name", "unnamed"), "expires", expiration.isoformat())
