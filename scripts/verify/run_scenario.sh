#!/usr/bin/env bash
# Two-persona end-to-end scenario on two iOS Simulators against LOCAL Supabase.
#
#   Alice's phone auto-shares a library photo of Bob (matched on-device) -> appears in Bob's Photos tab.
#   Also checks the negative case: a photo of Dan (not enrolled) is NOT uploaded.
#
# Usage: scripts/verify/run_scenario.sh            (from anywhere; needs docker/colima running)
# Evidence: verification-output/scenario-<timestamp>/{summary.md,screens/,logs/,db/}
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/verify/simlock.sh
simlock_acquire   # one simulator run at a time across worktrees

BUNDLE=com.ryanrosenfeld.photoshare
PASSWORD='Test1234!'
FIX=PhotoShareTests/Fixtures/faces
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$PWD/verification-output/scenario-$STAMP
DD=$PWD/verification-output/DerivedData
mkdir -p "$OUT"/screens "$OUT"/logs "$OUT"/db
SUMMARY=$OUT/summary.md
FAILS=0
echo "# Scenario run $STAMP" > "$SUMMARY"

log()  { echo "[$(date +%T)] $*" | tee -a "$OUT/logs/runner.log"; }
pass() { log "PASS: $*"; echo "- PASS: $*" >> "$SUMMARY"; }
fail() { log "FAIL: $*"; echo "- FAIL: $*" >> "$SUMMARY"; FAILS=$((FAILS+1)); }
skip() { log "SKIP: $*"; echo "- SKIPPED: $*" >> "$SUMMARY"; }
psql_q() { docker exec supabase_db_photo-sharing-app psql -U postgres -At -c "$1"; }

# ---- 0. backend -----------------------------------------------------------------------------
docker info >/dev/null 2>&1 || { log "docker not running (try: colima start --cpu 2 --memory 4)"; exit 2; }
if ! supabase status >/dev/null 2>&1; then
  log "starting local supabase"
  supabase stop --no-backup >/dev/null 2>&1   # clear a half-dead stack
  supabase start -x studio,imgproxy,edge-runtime,logflare,vector,mailpit,realtime,supavisor,postgres-meta \
    >"$OUT/logs/supabase-start.log" 2>&1 || { fail "supabase start"; exit 1; }
fi
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
log "resetting database (migrations + persona seed)"
supabase db reset >"$OUT/logs/db-reset.log" 2>&1 && pass "db reset: migrations + personas applied" || { fail "db reset"; exit 1; }
sleep 5  # let gotrue/postgrest/storage reload schema

login() { curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" \
  -H 'Content-Type: application/json' -d "{\"email\":\"$1@test.local\",\"password\":\"$PASSWORD\"}" | jq -r .access_token; }
BOB_ID=$(psql_q "select id from auth.users where email='bob@test.local'")
ALICE_ID=$(psql_q "select id from auth.users where email='alice@test.local'")
TOKEN=$(login bob)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] && pass "persona sign-in via API (bob)" || { fail "bob API login"; exit 1; }
n=0
for f in bob_1 bob_2; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/storage/v1/object/face-profiles/$BOB_ID/$n.jpg" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: image/jpeg' --data-binary "@$FIX/$f.jpg")
  [ "$code" = 200 ] || fail "upload bob face profile $f (HTTP $code)"
  n=$((n+1))
done
[ "$(psql_q "select count(*) from storage.objects where bucket_id='face-profiles'")" = 2 ] \
  && pass "Bob's face profile: 2 reference photos in storage" || fail "face profile photos not in storage"

# ---- 1. simulators (dedicated, capped at 2) ---------------------------------------------------
sim() { # name -> udid (create if missing)
  local u; u=$(xcrun simctl list devices | grep "    $1 (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
  [ -n "$u" ] || u=$(xcrun simctl create "$1" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
  echo "$u"
}
A=$(sim verify-alice); B=$(sim verify-bob)
# Personas run one simulator at a time (16 GB MacBook Air thrashes with 2 sims + Xcode + Docker);
# the hard cap is 2, and the personas are independent apart from the shared backend.
for u in $A $B; do xcrun simctl shutdown "$u" 2>/dev/null; done
for u in $A $B; do xcrun simctl erase "$u"; done
boot() { xcrun simctl boot "$1" 2>/dev/null; xcrun simctl bootstatus "$1" -b >/dev/null 2>&1; }
log "simulators: alice=$A bob=$B"

xcodegen generate >/dev/null
log "building for testing"
xcodebuild build-for-testing -project PhotoShare.xcodeproj -scheme PhotoShare \
  -destination "platform=iOS Simulator,id=$A" -derivedDataPath "$DD" >"$OUT/logs/build.log" 2>&1 \
  && pass "build-for-testing" || { fail "build-for-testing (see logs/build.log)"; exit 1; }
APP=$DD/Build/Products/Debug-iphonesimulator/PhotoShare.app
setup_sim() { boot "$1"; xcrun simctl install "$1" "$APP"; xcrun simctl privacy "$1" grant photos "$BUNDLE"; }

shot() { xcrun simctl io "$1" screenshot "$OUT/screens/$2.png" >/dev/null 2>&1; }
uistep() { # persona udid step [extra env...]
  local who=$1 udid=$2 step=$3; shift 3
  local res=$OUT/logs/$who-$step.xcresult
  env TEST_RUNNER_VERIFY_EMAIL="$who@test.local" TEST_RUNNER_VERIFY_PASSWORD="$PASSWORD" \
      TEST_RUNNER_VERIFY_SUPABASE_URL="$API_URL" TEST_RUNNER_VERIFY_SUPABASE_ANON_KEY="$ANON_KEY" "$@" \
    xcodebuild test-without-building -project PhotoShare.xcodeproj -scheme PhotoShare \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DD" \
      -only-testing:PhotoShareUITests/ScenarioTests/$step -resultBundlePath "$res" \
      >"$OUT/logs/$who-$step.log" 2>&1
  local rc=$?
  shot "$udid" "$who-$step"
  return $rc
}

setup_sim "$A" && pass "alice sim: booted, app installed, Photos permission granted (simctl privacy)"
# ---- 2. Alice signs in and enrolls Bob from Bob's face profile ---------------------------------
uistep alice "$A" testSignIn && pass "alice: sign in (UI)" || fail "alice: sign in (UI)"
uistep alice "$A" testEnrollFriendFromFaceProfile \
  && pass "alice: enrolled Bob from his face profile (UI; embeddings computed on-device)" \
  || fail "alice: enroll Bob (UI) — see logs/alice-testEnrollFriendFromFaceProfile.log"

# ---- 3. new photos land in Alice's library (after the processing cursor was seeded) -----------
sleep 2
# Fresh copies: the library's "new photo" cursor is by creation date, and addmedia keeps the file's own date.
mkdir -p "$OUT/addmedia"; cp "$FIX/bob_3.jpg" "$FIX/dan_3.jpg" "$OUT/addmedia/"
xcrun simctl addmedia "$A" "$OUT/addmedia/bob_3.jpg" "$OUT/addmedia/dan_3.jpg" && pass "alice: simctl addmedia (bob_3.jpg = photo of Bob, dan_3.jpg = photo of Dan, not a friend)"
shot "$A" alice-after-addmedia

# ---- 4. relaunch Alice with simctl (captures [AutoShare] stdout) --------------------------------
xcrun simctl terminate "$A" "$BUNDLE" 2>/dev/null
SIMCTL_CHILD_PHOTOSHARE_SUPABASE_URL="$API_URL" SIMCTL_CHILD_PHOTOSHARE_SUPABASE_ANON_KEY="$ANON_KEY" \
  xcrun simctl launch --terminate-running-process --stdout="$OUT/logs/alice-app-stdout.log" \
  --stderr="$OUT/logs/alice-app-stderr.log" "$A" "$BUNDLE" >/dev/null
for i in $(seq 1 30); do
  [ "$(psql_q "select count(*) from photo_recipients")" -ge 1 ] && break
  sleep 2
done
shot "$A" alice-after-autoshare
psql_q "select p.sender_id, pr.recipient_id, p.storage_path, p.taken_at from photos p join photo_recipients pr on pr.photo_id=p.id" > "$OUT/db/photo_recipients.txt"
SENT=$(psql_q "select count(*) from photos where sender_id='$ALICE_ID'")
TO_BOB=$(psql_q "select count(*) from photo_recipients where recipient_id='$BOB_ID'")
OBJ=$(psql_q "select count(*) from storage.objects where bucket_id='photos'")
[ "$SENT" = 1 ] && [ "$TO_BOB" = 1 ] && [ "$OBJ" = 1 ] \
  && pass "alice's phone matched Bob's face and uploaded exactly 1 photo to Bob (and did not upload Dan's)" \
  || fail "auto-share result wrong: photos from alice=$SENT, recipients bob=$TO_BOB, storage objects=$OBJ (expected 1/1/1); see logs/alice-app-stdout.log"
grep -E "\[AutoShare\]" "$OUT/logs/alice-app-stdout.log" > "$OUT/logs/alice-autoshare.txt" 2>/dev/null
xcrun simctl terminate "$A" "$BUNDLE" 2>/dev/null

# ---- 5. Bob signs in on the second simulator and sees the photo ---------------------------------
xcrun simctl shutdown "$A"
setup_sim "$B" && pass "bob sim: booted, app installed, Photos permission granted"
uistep bob "$B" testPhotosTabShowsReceivedPhotos TEST_RUNNER_VERIFY_EXPECT_PHOTOS=1 \
  && pass "bob: Photos tab shows the 1 photo from Alice (UI)" \
  || fail "bob: Photos tab (UI) — see logs/bob-testPhotosTabShowsReceivedPhotos.log"

# ---- not covered ----------------------------------------------------------------------------------
skip "simctl push: app has no APNs registration / device_tokens / edge function yet (SPEC v3 feature), nothing to verify"
skip "simctl openurl: only auth callbacks (photoshare://) are handled; friend-invite deep links are not implemented yet"

xcrun simctl shutdown "$A" 2>/dev/null; xcrun simctl shutdown "$B" 2>/dev/null
echo >> "$SUMMARY"; echo "Artifacts: screens/, logs/, db/ in $OUT" >> "$SUMMARY"
log "done: $FAILS failure(s). Summary: $SUMMARY"
cat "$SUMMARY"
exit $((FAILS>0))
