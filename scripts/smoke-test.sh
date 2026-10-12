#!/bin/bash
# Requires the SIGNED, INSTALLED, APPROVED extension on a real Mac.
set -euo pipefail
CLI=/Applications/USBWakeCam.app/Contents/MacOS/phonecam
[[ "$(uname -s)" == Darwin && -x "$CLI" ]] || { echo "Install and approve PhoneCam on a Mac first." >&2; exit 1; }
DIR="$(mktemp -d "${TMPDIR:-/tmp}/phonecam-smoke.XXXXXX")"
PID=""
cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  rm -rf "$DIR"
}
trap cleanup EXIT
"$CLI" run --source test --duration 12 --json > "$DIR/producer.json" 2> "$DIR/producer.log" &
PID=$!
sleep 2
if ! kill -0 "$PID" 2>/dev/null; then cat "$DIR/producer.log" >&2; echo "Producer failed." >&2; exit 1; fi
if ! "$CLI" probe --device "USB WakeCam" --duration 5 --json > "$DIR/consumer.json"; then
  cat "$DIR/producer.log" >&2; exit 1
fi
wait "$PID"
PID=""
echo "Producer report:"; cat "$DIR/producer.json"
echo "Consumer report:"; cat "$DIR/consumer.json"
echo "PASS: a second AVFoundation process read virtual-camera samples. Also visually verify moving bars; frame counts alone do not rule out black frames."
