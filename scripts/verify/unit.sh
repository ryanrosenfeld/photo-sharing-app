#!/bin/bash
# Run unit tests under the shared simulator lock, retrying the occasional simulator launch failure.
cd "$(dirname "$0")/../.."
for i in 1 2 3; do
  scripts/verify/simlock.sh make test-unit >/dev/null 2>&1
  grep -q "TEST SUCCEEDED\|Executed .* tests" verification-output/unit.log && ! grep -q "server died" verification-output/unit.log && break
  sleep 20
done
tail -4 verification-output/unit.log | head -1; grep -a "error:\|failed" verification-output/unit.log | head
cat verification-output/face-match-report.txt
