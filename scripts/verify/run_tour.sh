#!/usr/bin/env bash
# Screenshot + recording tour of the signed-in app (Photos shelf, photo detail, Friends, Profile) as seeded persona Bob,
# against the LOCAL Supabase as it is (no db reset). Used for before/after UI comparisons.
#   scripts/verify/run_tour.sh <label>      -> verification-output/tour-<label>/{tour.mp4,screens/,logs/}
# Takes the shared simulator lock and shuts down only its own device afterwards.
set -uo pipefail
source "$(dirname "$0")/recording-lib.sh"
cd "$(dirname "$0")/../.."
LABEL=${1:-run}
OUT=$PWD/verification-output/tour-$LABEL
DD=$PWD/verification-output/DerivedData
rm -rf "$OUT"; mkdir -p "$OUT"/screens "$OUT"/logs
source scripts/verify/simlock-lib.sh
simlock_acquire
S=""
cleanup() { [ -n "$S" ] && xcrun simctl shutdown "$S" 2>/dev/null; rm -rf "$LOCK"; }
trap cleanup EXIT
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
NAME=liquidglass-shots
S=$(xcrun simctl list devices | grep "    $NAME (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
[ -n "$S" ] || S=$(xcrun simctl create "$NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
xcrun simctl shutdown "$S" 2>/dev/null; xcrun simctl erase "$S"
xcrun simctl boot "$S" && xcrun simctl bootstatus "$S" -b >/dev/null 2>&1
xcrun simctl ui "$S" appearance light 2>/dev/null
xcodegen generate >/dev/null
xcodebuild build-for-testing -project PhotoShare.xcodeproj -scheme PhotoShare -destination "platform=iOS Simulator,id=$S" \
  -derivedDataPath "$DD" >"$OUT/logs/build.log" 2>&1 || { echo "build failed: $OUT/logs/build.log"; exit 1; }
( export TEST_RUNNER_VERIFY_EMAIL=bob@test.local TEST_RUNNER_VERIFY_PASSWORD='Test1234!' \
         TEST_RUNNER_VERIFY_SUPABASE_URL="$API_URL" TEST_RUNNER_VERIFY_SUPABASE_ANON_KEY="$ANON_KEY"
  run_recorded "$S" "$OUT/tour.mp4" "$OUT/logs/tour.log" \
    xcodebuild test-without-building -collect-test-diagnostics never -project PhotoShare.xcodeproj -scheme PhotoShare \
      -destination "platform=iOS Simulator,id=$S" -derivedDataPath "$DD" \
      -only-testing:PhotoShareUITests/ScenarioTests/testTourScreens -resultBundlePath "$OUT/logs/tour.xcresult" )
RC=$?
xcrun xcresulttool export attachments --path "$OUT/logs/tour.xcresult" --output-path "$OUT/raw" >/dev/null 2>&1
python3 - "$OUT" <<'PY'
import json, shutil, sys, os
o = sys.argv[1]; m = json.load(open(f"{o}/raw/manifest.json"))
for t in m:
    for a in t.get("attachments", []):
        n = a.get("suggestedHumanReadableName", "").split("_")[0]
        if n.startswith("tour-"): shutil.copy(f"{o}/raw/{a['exportedFileName']}", f"{o}/screens/{n}.png")
PY
echo "tour $LABEL rc=$RC -> $OUT"; exit $RC
