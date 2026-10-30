#!/usr/bin/env bash

set -u

artifact_dir=build/metadata-smoke-artifacts
mkdir -p "$artifact_dir" || exit $?

flutter drive \
  --driver=test/driver/metadata_smoke_driver.dart \
  --target=test/integration/metadata_smoke.dart \
  -d emulator-5554 \
  --dart-define=CI_NATIVE_SMOKE=true
smoke_result=$?

# These captures are best-effort diagnostics and must not replace the driver
# result, especially when the test itself has failed.
if ! adb -s emulator-5554 exec-out screencap -p \
  >"$artifact_dir/device-final.png" 2>&1; then
  printf '%s\n' 'Warning: failed to capture the final emulator screenshot.' >&2
fi
if ! adb -s emulator-5554 logcat -d -t 1200 \
  >"$artifact_dir/android-logcat.txt" 2>&1; then
  printf '%s\n' 'Warning: failed to collect emulator logcat.' >&2
fi

if [ "$smoke_result" -ne 0 ]; then
  exit "$smoke_result"
fi

python3 - "$artifact_dir/manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as manifest_file:
    manifest = json.load(manifest_file)
if manifest.get('passed') is not True:
    raise SystemExit('Metadata smoke manifest did not report passed=true.')
PY
