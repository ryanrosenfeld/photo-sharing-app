#!/usr/bin/env bash
# Evidence-only recording of the Photos tab: error state + Try again, pull to refresh, Save all, tab bar.
# Bob (seeded) receives photos from Alice; the API is stopped before the Photos tab loads, restored after the error shows.
# Output: verification-output/photos-<ts>/{photos.mp4,screens/,logs/}
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/verify/simlock-lib.sh
simlock_acquire

BUNDLE=com.ryanrosenfeld.photoshare
PASSWORD='Test1234!'
FIX=PhotoShareTests/Fixtures/faces
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$PWD/verification-output/photos-$STAMP
DD=$PWD/verification-output/DerivedData
M=$OUT/markers
mkdir -p "$OUT"/screens "$OUT"/logs "$M"
log() { echo "[$(date +%T)] $*" | tee -a "$OUT/logs/runner.log"; }
psql_q() { docker exec supabase_db_photo-sharing-app psql -U postgres -At -c "$1"; }
break_api() { psql_q "alter table if exists photo_recipients rename to photo_recipients_off" >/dev/null; }
fix_api() { psql_q "alter table if exists photo_recipients_off rename to photo_recipients" >/dev/null 2>&1; }
VIDPID=""
cleanup() { [ -n "$VIDPID" ] && kill -INT "$VIDPID" 2>/dev/null; fix_api; xcrun simctl shutdown "${S:-}" 2>/dev/null; rm -rf /tmp/photoshare-sim.lock; }
trap cleanup EXIT

docker info >/dev/null 2>&1 || { log "docker not running"; exit 2; }
supabase status >/dev/null 2>&1 || supabase start -x studio,imgproxy,edge-runtime,logflare,vector,mailpit,realtime,supavisor,postgres-meta >"$OUT/logs/supabase-start.log" 2>&1
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY)=')"
supabase db reset >"$OUT/logs/db-reset.log" 2>&1 || { log "db reset failed"; exit 1; }
sleep 5
ALICE_ID=$(psql_q "select id from auth.users where email='alice@test.local'")
BOB_ID=$(psql_q "select id from auth.users where email='bob@test.local'")

seed_photo() { # fixture
  local path="photos/$(uuidgen).jpg"
  curl -s -o /dev/null -X POST "$API_URL/storage/v1/object/photos/$path" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'Content-Type: image/jpeg' --data-binary "@$FIX/$1.jpg"
  local id; id=$(psql_q "insert into photos (sender_id, storage_path, taken_at) values ('$ALICE_ID','$path', now()) returning id" | head -1)
  psql_q "insert into photo_recipients (photo_id, recipient_id) values ('$id','$BOB_ID')" >/dev/null
}
seed_photo bob_1

sim() { local u; u=$(xcrun simctl list devices | grep "    $1 (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
        [ -n "$u" ] || u=$(xcrun simctl create "$1" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro); echo "$u"; }
S=$(sim verify-photos)
xcrun simctl shutdown "$S" 2>/dev/null; xcrun simctl erase "$S"
xcrun simctl boot "$S" && xcrun simctl bootstatus "$S" -b >/dev/null 2>&1
xcodegen generate >/dev/null
xcodebuild build-for-testing -project PhotoShare.xcodeproj -scheme PhotoShare -destination "platform=iOS Simulator,id=$S" \
  -derivedDataPath "$DD" >"$OUT/logs/build.log" 2>&1 || { log "build failed"; exit 1; }
APP=$DD/Build/Products/Debug-iphonesimulator/PhotoShare.app
xcrun simctl install "$S" "$APP"; xcrun simctl privacy "$S" grant photos "$BUNDLE"

step() { # step [extra env...]
  local st=$1; shift
  env TEST_RUNNER_VERIFY_EMAIL=bob@test.local TEST_RUNNER_VERIFY_PASSWORD="$PASSWORD" \
      TEST_RUNNER_VERIFY_SUPABASE_URL="$API_URL" TEST_RUNNER_VERIFY_SUPABASE_ANON_KEY="$ANON_KEY" "$@" \
    xcodebuild test-without-building -project PhotoShare.xcodeproj -scheme PhotoShare -destination "platform=iOS Simulator,id=$S" \
      -derivedDataPath "$DD" -only-testing:PhotoShareUITests/ScenarioTests/$st -resultBundlePath "$OUT/logs/$st.xcresult" >"$OUT/logs/$st.log" 2>&1
  local rc=$?
  xcrun xcresulttool export attachments --path "$OUT/logs/$st.xcresult" --output-path "$OUT/screens/$st" >/dev/null 2>&1
  return $rc
}
step testSignIn && log "PASS sign in" || { log "FAIL sign in"; exit 1; }

break_api
( while [ ! -e "$M/error-seen" ]; do sleep 1; done; sleep 8; fix_api
  while [ ! -e "$M/stack-seen" ]; do sleep 1; done; sleep 4; seed_photo bob_2 ) &
WATCH=$!
xcrun simctl io "$S" recordVideo --codec h264 --force "$OUT/photos.mp4" >"$OUT/logs/record.log" 2>&1 &
VIDPID=$!; sleep 2
step testPhotosWalkthrough TEST_RUNNER_VERIFY_MARKER_DIR="$M" && log "PASS photos walkthrough" || log "FAIL photos walkthrough (logs/testPhotosWalkthrough.log)"
kill -INT $VIDPID 2>/dev/null; wait $VIDPID 2>/dev/null; VIDPID=""
kill $WATCH 2>/dev/null
log "done: $OUT"
