#!/usr/bin/env bash
# New-account onboarding on a fresh simulator vs LOCAL Supabase: sign up -> face profile (3 good + 1 rejected photo)
# -> photo access -> notifications -> home; then a relaunch that must skip onboarding.
# Evidence: verification-output/onboarding-<ts>/{summary.md,onboarding.mp4,screens/,logs/}
# Takes the shared simulator lock (/tmp/photoshare-sim.lock) and shuts down only its own simulator afterwards.
set -uo pipefail
source "$(dirname "$0")/recording-lib.sh"
cd "$(dirname "$0")/../.."

BUNDLE=com.ryanrosenfeld.photoshare
PASSWORD='Test1234!'
EMAIL="erin$(date +%s)@test.local"
EMAIL2="finn$(date +%s)@test.local"
EMAIL3="gia$(date +%s)@test.local"
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
source scripts/verify/simlock-lib.sh
simlock_acquire   # stale-aware: a lock left by a dead run is taken over
cleanup() {
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
supabase migration up --local >"$OUT/logs/migrations.log" 2>&1 || log "migration up failed (see logs/migrations.log)"
# Invites from the seeded personas (supabase db reset loads supabase/seed_personas.sql): Dan for the invited sign-up,
# Carol for the paste-a-link test.
[ -n "$(psql_q "select 1 from profiles where id='d4444444-4444-4444-4444-444444444444'")" ] || supabase db reset >"$OUT/logs/db-reset.log" 2>&1
INVITE=$(psql_q "insert into invites (inviter_id) values ('d4444444-4444-4444-4444-444444444444') returning code" | head -1)
INVITE2=$(psql_q "insert into invites (inviter_id) values ('c3333333-3333-3333-3333-333333333333') returning code" | head -1)
[ ${#INVITE} = 32 ] && [ ${#INVITE2} = 32 ] && pass "invites created for Dan and Carol" || fail "could not create persona invites"
ANON_PREVIEW=$(curl -s -X POST "$API_URL/rest/v1/rpc/preview_invite_public" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -d "{\"p_code\":\"$INVITE\"}")
echo "$ANON_PREVIEW" | grep -q '"inviter_name":"Dan","usable":true' && pass "signed-out preview names the inviter: $ANON_PREVIEW" || fail "public preview: $ANON_PREVIEW"

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
# One device per checkout, so a run in another worktree can never erase or shut down this one mid-test.
S=$(sim "verify-onboarding-$(printf %s "$PWD" | shasum | cut -c1-8)")
xcrun simctl shutdown "${S:-}" 2>/dev/null
xcrun simctl erase "$S"
xcrun simctl boot "$S" && xcrun simctl bootstatus "$S" -b >/dev/null 2>&1

xcodegen generate >/dev/null
xcodebuild build-for-testing -project PhotoShare.xcodeproj -scheme PhotoShare \
  -destination "platform=iOS Simulator,id=$S" -derivedDataPath "$DD" >"$OUT/logs/build.log" 2>&1 \
  && pass "build-for-testing" || { fail "build-for-testing (logs/build.log)"; exit 1; }
xcrun simctl addmedia "$S" "$OUT"/media/*.jpg && pass "4 photos added to the library (3 portraits, 1 landscape without a face)"

run() { # test name; RECORD=0 skips the video (default: tight clip per test in videos/, joined into onboarding.mp4)
  local res=$OUT/logs/$1.xcresult
  mkdir -p "$OUT/videos"
  ( export TEST_RUNNER_VERIFY_SUPABASE_URL="$API_URL" TEST_RUNNER_VERIFY_SUPABASE_ANON_KEY="$ANON_KEY" \
           TEST_RUNNER_VERIFY_NEW_EMAIL="$EMAIL" TEST_RUNNER_VERIFY_PASSWORD="$PASSWORD" \
           TEST_RUNNER_VERIFY_NEW_EMAIL2="$EMAIL2" TEST_RUNNER_VERIFY_INVITE_CODE="$INVITE" TEST_RUNNER_VERIFY_INVITE_CODE2="$INVITE2" \
           TEST_RUNNER_VERIFY_NEW_EMAIL3="$EMAIL3" TEST_RUNNER_VERIFY_SELFIE_FIXTURES="$PWD/$FIX/alice_1.jpg,$PWD/$FIX/alice_2.jpg,$PWD/$FIX/alice_3.jpg"
    if [ "${RECORD:-1}" = 1 ]; then
      run_recorded "$S" "$OUT/videos/$1.mp4" "$OUT/logs/$1.log" \
        xcodebuild test-without-building -collect-test-diagnostics never -project PhotoShare.xcodeproj -scheme PhotoShare \
          -destination "platform=iOS Simulator,id=$S" -derivedDataPath "$DD" \
          -only-testing:PhotoShareUITests/OnboardingTests/$1 -resultBundlePath "$res"
    else
      xcodebuild test-without-building -collect-test-diagnostics never -project PhotoShare.xcodeproj -scheme PhotoShare \
        -destination "platform=iOS Simulator,id=$S" -derivedDataPath "$DD" \
        -only-testing:PhotoShareUITests/OnboardingTests/$1 -resultBundlePath "$res" >"$OUT/logs/$1.log" 2>&1
    fi )
  local rc=$?
  xcrun xcresulttool export attachments --path "$res" --output-path "$OUT/screens/$1" >/dev/null 2>&1
  return $rc
}
run testNewAccountOnboarding && pass "new account: sign up -> face profile -> photo access -> first friend (QR, skip) -> notifications -> home; Friends shows the waiting invite, Add Friend copy/new link/cancel (UI)" \
  || fail "new account onboarding (logs/testNewAccountOnboarding.log)"
run testRelaunchSkipsOnboarding && pass "relaunch goes straight to the app; Profile shows permissions, no way to turn the face profile off (UI)" \
  || fail "relaunch (logs/testRelaunchSkipsOnboarding.log)"
run testPasteInvite && pass "Friends -> paste a link: junk is explained, a pasted message opens Carol's accept screen (UI)" \
  || fail "paste invite (logs/testPasteInvite.log)"
run testInvitedNewAccount && pass "signed-out invitee: 'Dan invited you', survives a kill, sign-up, no first-friend step, accept right after onboarding (UI)" \
  || fail "invited new account (logs/testInvitedNewAccount.log)"
run testGuidedSelfies && pass "guided selfies: straight, turn, turn the other way captured on their own, 3 accepted, onboarding continues (UI, stand-in camera frames)" \
  || fail "guided selfies (logs/testGuidedSelfies.log)"

# ---- backend state ----
[ "$(psql_q "select face_profile_enabled from profiles p join auth.users u on u.id=p.id where u.email='$EMAIL'")" = t ] \
  && pass "profiles.face_profile_enabled = true for the new account" || fail "face_profile_enabled not set"
N=$(psql_q "select count(*) from storage.objects o join auth.users u on o.name like u.id::text||'/%' where o.bucket_id='face-profiles' and u.email='$EMAIL'")
[ "$N" = 3 ] && pass "exactly 3 reference photos uploaded (the rejected landscape was not)" || fail "expected 3 uploaded photos, found $N"

N=$(psql_q "select count(*) from invites i join auth.users u on u.id=i.inviter_id where u.email='$EMAIL' and i.accepted_at is null")
[ "$N" = 2 ] && pass "Erin has 2 open invites after onboarding link + copied link + new link - 1 cancelled" || fail "expected 2 open invites for Erin, found $N"
[ "$(psql_q "select count(*) from friendships f join auth.users u on u.id=f.user_id where u.email='$EMAIL2' and f.friend_id='d4444444-4444-4444-4444-444444444444'")" = 1 ] \
  && pass "Finn and Dan are friends after the invited sign-up" || fail "Finn-Dan friendship missing"
N=$(psql_q "select count(*) from storage.objects o join auth.users u on o.name like u.id::text||'/%' where o.bucket_id='face-profiles' and u.email='$EMAIL3'")
[ "$N" = 3 ] && pass "3 selfies uploaded as the selfie account's face profile" || fail "expected 3 selfie uploads, found $N"
[ "$(psql_q "select accepted_at is null from invites where code='$INVITE2'")" = t ] && pass "declining Carol's pasted invite leaves it unused" || fail "Carol's invite was consumed"

[ "${RECORD:-1}" = 1 ] && join_clips "$OUT/onboarding.mp4" "$OUT"/videos/*.mp4
echo; cat "$SUMMARY"; echo "Evidence: $OUT"
exit $FAILS
