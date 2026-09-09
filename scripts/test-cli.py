#!/usr/bin/env python3
"""Exercise the built/installed CLI without camera permission or extension activation."""
import argparse
import json
from pathlib import Path
import queue
import re
import signal
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cli", default=str(Path(__file__).resolve().parent.parent / "dist/PhoneCam.app/Contents/MacOS/phonecam"))
args = parser.parse_args()
checks = 0


def run(arguments, expected=0):
    result = subprocess.run([args.cli, *arguments], capture_output=True, text=True, timeout=30)
    if result.returncode != expected:
        raise AssertionError(f"{arguments}: exit {result.returncode}, expected {expected}: {result.stderr}\n{result.stdout}")
    return result


def passed(name):
    global checks
    checks += 1
    print(f"PASS: {name}", flush=True)


assert run(["version"]).stdout.strip() == "1.0.0"
assert run(["--version"]).stdout.strip() == "1.0.0"
passed("version and --version")
help_text = run(["help"]).stdout
assert "phonecam probe" in help_text and "phonecam preview" in help_text and "--syphon" in help_text
passed("help")
assert "FPS must" in run(["probe", "--fps", "0"], expected=64).stderr
assert "Unknown command" in run(["not-a-command"], expected=64).stderr
passed("invalid arguments return EX_USAGE")
result = run(["probe", "--source", "test", "--syphon", "--syphon-framework", "/nonexistent-phonecam-test/Syphon.framework"], expected=1)
assert "Syphon.framework is unavailable" in result.stderr
assert "received=" not in result.stderr
passed("missing optional Syphon framework fails before capture")

for size, rate, angle, fit in [("640x480", "15", "0", "fit"),
                              ("1280x720", "30", "90", "fit"),
                              ("1920x1080", "60", "270", "fill")]:
    # A fresh runner may spend more than one second initializing its render pipeline.
    # Keep a bounded capture interval and still require actual processed frames.
    result = run(["probe", "--source", "test", "--duration", "5", "--size", size,
                  "--fps", rate, "--rotate", angle, "--mirror", "--fit", fit, "--json"])
    report = json.loads(result.stdout)
    assert report["source"] == "test" and report["outputSize"] == size
    assert report["requestedFPS"] == int(rate)
    assert report["received"] > 0 and report["processed"] > 0
    assert report["queueDrops"] == 0
    passed(f"test frames {size} / {rate} fps / rotate {angle} / mirror / {fit}")

process = subprocess.Popen([args.cli, "probe", "--source", "test", "--duration", "60", "--json"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
progress = queue.Queue()
stderr_lines = []


def read_progress():
    for line in process.stderr:
        stderr_lines.append(line)
        progress.put(line)
    progress.put(None)


reader = threading.Thread(target=read_progress, daemon=True)
reader.start()
try:
    # Exercise cancellation during capture, after the process confirms its first output.
    deadline = time.monotonic() + 20
    while True:
        remaining = deadline - time.monotonic()
        assert remaining > 0, "Timed out waiting for processed frames: " + "".join(stderr_lines)
        try:
            line = progress.get(timeout=remaining)
        except queue.Empty:
            raise AssertionError("No capture progress before deadline: " + "".join(stderr_lines)) from None
        assert line is not None, "Capture exited before processing frames: " + "".join(stderr_lines)
        match = re.search(r"\bprocessed=(\d+)", line)
        if match and int(match.group(1)) > 0:
            break
    process.send_signal(signal.SIGINT)
    process.wait(timeout=10)
    reader.join(timeout=1)
    stdout = process.stdout.read()
    assert process.returncode == 0, "".join(stderr_lines)
    assert json.loads(stdout)["processed"] > 0
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=10)
    reader.join(timeout=1)
    process.stdout.close()
    process.stderr.close()
passed("SIGINT stops capture and returns final JSON")

report = json.loads(run(["doctor", "--json"]).stdout)
assert isinstance(report["metalAvailable"], bool)
assert isinstance(report["virtualCameraPresent"], bool)
assert isinstance(report["devices"]["androidUSB"], list)
passed("doctor JSON schema")
if not report["virtualCameraPresent"]:
    assert "extension is unavailable" in run(["run", "--source", "test", "--duration", "1"], expected=1).stderr
    passed("missing extension fails instead of claiming to publish")
else:
    print("SKIP: missing-extension check (extension is already present)")

print(f"Passed {checks} CLI integration checks.")
