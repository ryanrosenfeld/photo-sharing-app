#!/usr/bin/env bash
# New-account onboarding on a fresh simulator vs LOCAL Supabase: sign up -> face profile (3 good + 1 rejected photo)
# -> photo access -> notifications -> home; then a relaunch that must skip onboarding.
# Evidence: verification-output/onboarding-<ts>/{summary.md,onboarding.mp4,screens/,logs/}
# Takes the shared simulator lock (/tmp/photoshare-sim.lock) and shuts down only its own simulator afterwards.
set -uo pipefail
cd "$(dirname "$0")/../.."

BUNDLE=com.ryanrosenfeld.photoshare
PASSWORD='Test1234!'
EMAIL="erin$(date +%s)@test.local"
FIX=PhotoShareTests/Fixtures/faces
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$PWD/verification-output/onboarding-$STAMP
DD=$PWD/verification-output/DerivedData
mkdir -p "$OUT"/screens "$OUT"/logs
SUMMARY=$OUT/summary.md
FAILS=0
echo "# Onboarding run $STAMP" > "$SUMMARY"
log()  { echo "[$(date +%T)] $*" | tee -a "$OUT/logs/runner.log"; }
pass() { log "PASS: $*"; echo "- PASS: $*" >> "$SUMMARY"; }
fail() { log "FAIL: $*"; echo "- FAIL: $*" >> "$SUMMARY"; FAILS=$((FAILS+1)); }

# ---- shared simulator lock (other workstreams share this Mac) ----
LOCK=/tmp/photoshare-sim.lock
until mkdir "$LOCK" 2>/dev/null; do log "waiting for simulator lock"; sleep 15; done
echo $$ > "$LOCK/pid"
VIDPID=""
cleanup() {
  [ -n "$VIDPID" ] && kill -INT "$VIDPID" 2>/dev/null
  xcrun simctl shutdown "${S:-}" 2>/dev/null
  rm -rf "$LOCK"
}
trap cleanup EXIT

# ---- backend ----
docker info >/dev/null 2>&1 || { log "docker not running (try: colima start --cpu 2 --memory 4)"; exit 2; }
if ! supabase status >/dev/null 2>&1; then
  supabase stop --no-backup >/dev/null 2>&1
  supabase start -x studio,imgproxy,edge-runtime,logflare,vector,mailpit,realtime,supavisor,postgres-meta \
    >"$OUT/logs/supabase-start.log" 2>&1 || { fail "supabase start"; exit 1; }
fi
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
psql_q() { docker exec supabase_db_photo-sharing-app psql -U postgres -At -c "$1"; }

# ---- fixtures: 3 portraits + 1 landscape with no face (rendered, no network) ----
mkdir -p "$OUT/media"
cp "$FIX/alice_1.jpg" "$FIX/alice_2.jpg" "$FIX/alice_3.jpg" "$OUT/media/"
python3 - "$OUT/media/landscape_no_face.jpg" <<'PY'
import sys
from PIL import Image, ImageDraw
im = Image.new("RGB", (1200, 800)); d = ImageDraw.Draw(im)
for y in range(800): d.line([(0, y), (1200, y)], fill=(90 + y // 8, 150 + y // 10, 220))
d.polygon([(0, 800), (350, 380), (700, 800)], fill=(70, 90, 70)); d.polygon([(400, 800), (850, 330), (1200, 800)], fill=(50, 70, 60))
im.save(sys.argv[1], quality=90)
PY

# ---- simulator ----
sim() { local u; u=$(xcrun simctl list devices | grep "    $1 (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
        [ -n "$u" ] || u=$(xcrun simctl create "$1" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro); echo "$u"; }
S=$(sim verify-onboarding)
xcrun simctl shutdown "${S:-}" 2>/dev/null
xcrun simctl erase "$S"
xcrun simctl boot "$S" && xcrun simctl bootstatus "$S" -b >/dev/null 2>&1

xcodegen generate >/dev/null
xcodebuild build-for-testing -project PhotoShare.xcodeproj -scheme PhotoShare \
  -destination "platform=iOS Simulator,id=$S" -derivedDataPath "$DD" >"$OUT/logs/build.log" 2>&1 \
  && pass "build-for-testing" || { fail "build-for-testing (logs/build.log)"; exit 1; }
xcrun simctl addmedia "$S" "$OUT"/media/*.jpg && pass "4 photos added to the library (3 portraits, 1 landscape without a face)"

if [ "${RECORD:-1}" = 1 ]; then
  xcrun simctl io "$S" recordVideo --codec h264 --force "$OUT/onboarding.mp4" >"$OUT/logs/record.log" 2>&1 &
  VIDPID=$!
  sleep 2
fi

run() { # test name
  local res=$OUT/logs/$1.xcresult
  env TEST_RUNNER_VERIFY_SUPABASE_URL="$API_URL" TEST_RUNNER_VERIFY_SUPABASE_ANON_KEY="$ANON_KEY" \
      TEST_RUNNER_VERIFY_NEW_EMAIL="$EMAIL" TEST_RUNNER_VERIFY_PASSWORD="$PASSWORD" \
    xcodebuild test-without-building -project PhotoShare.xcodeproj -scheme PhotoShare \
      -destination "platform=iOS Simulator,id=$S" -derivedDataPath "$DD" \
      -only-testing:PhotoShareUITests/OnboardingTests/$1 -resultBundlePath "$res" >"$OUT/logs/$1.log" 2>&1
  local rc=$?
  xcrun xcresulttool export attachments --path "$res" --output-path "$OUT/screens/$1" >/dev/null 2>&1
  return $rc
}
run testNewAccountOnboarding && pass "new account: sign up -> face profile -> photo access -> notifications -> home (UI)" \
  || fail "new account onboarding (logs/testNewAccountOnboarding.log)"
run testRelaunchSkipsOnboarding && pass "relaunch goes straight to the app; Profile shows permissions, no way to turn the face profile off (UI)" \
  || fail "relaunch (logs/testRelaunchSkipsOnboarding.log)"

# ---- backend state ----
[ "$(psql_q "select face_profile_enabled from profiles p join auth.users u on u.id=p.id where u.email='$EMAIL'")" = t ] \
  && pass "profiles.face_profile_enabled = true for the new account" || fail "face_profile_enabled not set"
N=$(psql_q "select count(*) from storage.objects o join auth.users u on o.name like u.id::text||'/%' where o.bucket_id='face-profiles' and u.email='$EMAIL'")
[ "$N" = 3 ] && pass "exactly 3 reference photos uploaded (the rejected landscape was not)" || fail "expected 3 uploaded photos, found $N"

[ -n "$VIDPID" ] && { kill -INT "$VIDPID" 2>/dev/null; wait "$VIDPID" 2>/dev/null; VIDPID=""; }
echo; cat "$SUMMARY"; echo "Evidence: $OUT"
exit $FAILS
