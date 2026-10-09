#!/bin/bash
# Run unit tests under the shared simulator lock on a dedicated device, retrying the occasional launch failure.
cd "$(dirname "$0")/../.."
export SIM_NAME=${SIM_NAME:-facematch-iphone}
xcrun simctl list devices | grep -q "$SIM_NAME " || xcrun simctl create "$SIM_NAME" "iPhone 17 Pro" >/dev/null
for i in 1 2 3; do
  scripts/verify/simlock.sh make test-unit >/dev/null 2>&1
  grep -q "TEST SUCCEEDED\|Executed .* tests" verification-output/unit.log && ! grep -q "server died" verification-output/unit.log && break
  sleep 20
done
grep -a "error:\|failed" verification-output/unit.log | head
tail -4 verification-output/unit.log | head -1
cat verification-output/face-match-report.txt
