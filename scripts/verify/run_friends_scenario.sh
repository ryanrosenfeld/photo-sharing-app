#!/usr/bin/env bash
# Friends v3 scenario: invite link -> deep link -> accept -> per-friend Send/Receive toggles -> unfriend.
# Two simulators used one at a time against LOCAL Supabase (dan = inviter on sim A, carol = invitee on sim B).
#
#   1. dan (A):   Add Friend -> invite link shown; link == the invites row in the DB
#   2. carol (B): `simctl openurl photoshare://invite/<code>` -> accept screen -> Accept -> friend row for Dan
#                 DB: 2 friendships rows, all four toggles ON, invite consumed
#   3. negatives: API accept of a used / own / unknown code is refused; carol opening the used link sees why (UI)
#   4. dan (A):   turns Receive OFF for Carol          -> DB + carol's row says Paused (UI)
#   5. server enforcement: carol cannot deliver a photo to dan (RLS) while dan's Receive is OFF, can once it is ON,
#                 and cannot after carol turns Send OFF in the UI
#   6. dan (A):   Unfriend -> both rows gone, list empty (UI)
#
# Usage: scripts/verify/run_friends_scenario.sh  (needs docker/colima). Takes the shared simulator lock.
# Evidence: verification-output/friends-<ts>/{summary.md,screens/,videos/,logs/,db/}
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/verify/simlock-lib.sh
simlock_acquire

BUNDLE=com.ryanrosenfeld.photoshare
PASSWORD='Test1234!'
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$PWD/verification-output/friends-$STAMP
DD=$PWD/verification-output/DerivedData
mkdir -p "$OUT"/screens "$OUT"/videos "$OUT"/logs "$OUT"/db
SUMMARY=$OUT/summary.md; FAILS=0
echo "# Friends v3 scenario $STAMP" > "$SUMMARY"
log()  { echo "[$(date +%T)] $*" | tee -a "$OUT/logs/runner.log"; }
pass() { log "PASS: $*"; echo "- PASS: $*" >> "$SUMMARY"; }
fail() { log "FAIL: $*"; echo "- FAIL: $*" >> "$SUMMARY"; FAILS=$((FAILS+1)); }
check() { # description, condition-exit-status
  if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; fi; }
psql_q() { docker exec supabase_db_photo-sharing-app psql -U postgres -At -c "$1"; }

# ---- backend ------------------------------------------------------------------------------------
docker info >/dev/null 2>&1 || { log "docker not running (colima start --cpu 2 --memory 4)"; exit 2; }
if ! supabase status >/dev/null 2>&1; then
  log "starting local supabase"
  supabase start -x studio,imgproxy,edge-runtime,logflare,vector,mailpit,realtime,supavisor,postgres-meta \
    >"$OUT/logs/supabase-start.log" 2>&1 || { fail "supabase start"; exit 1; }
fi
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
log "resetting database (migrations + persona seed)"
supabase db reset >"$OUT/logs/db-reset.log" 2>&1 && pass "db reset: migrations (incl. mutual_friendships) + personas applied" || { fail "db reset"; exit 1; }
# wait until auth + rest answer after the reset (they restart; a fixed sleep is not enough on a loaded Mac)
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -d '{"email":"dan@test.local","password":"Test1234!"}')" = 200 ] && break; sleep 3
done

token() { curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" \
  -H 'Content-Type: application/json' -d "{\"email\":\"$1@test.local\",\"password\":\"$PASSWORD\"}" | jq -r .access_token; }
EMPTY_JSON='{}'
rpc() { # persona fn json-body  -> prints body, sets RPC_CODE
  local resp; resp=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/rest/v1/rpc/$2" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $(token "$1")" -H 'Content-Type: application/json' -d "${3:-$EMPTY_JSON}")
  RPC_CODE=$(echo "$resp" | tail -1); echo "$resp" | sed '$d'; }
id_of() { psql_q "select id from auth.users where email='$1@test.local'"; }
DAN=$(id_of dan); CAROL=$(id_of carol); ALICE=$(id_of alice)
fr() { psql_q "select send_enabled::int || receive_enabled::int from friendships where user_id='$1' and friend_id='$2'"; }

# ---- simulators ---------------------------------------------------------------------------------
sim() { local u; u=$(xcrun simctl list devices | grep "    $1 (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
  [ -n "$u" ] || u=$(xcrun simctl create "$1" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro); echo "$u"; }
A=$(sim verify-friends-a); B=$(sim verify-friends-b)   # A hosts dan, B hosts carol
for u in $A $B; do xcrun simctl shutdown "$u" 2>/dev/null; done
for u in $A $B; do xcrun simctl erase "$u"; done
boot() { xcrun simctl boot "$1" 2>/dev/null; xcrun simctl bootstatus "$1" -b >/dev/null 2>&1; }
xcodegen generate >/dev/null
log "building for testing"
xcodebuild build-for-testing -project PhotoShare.xcodeproj -scheme PhotoShare -destination "platform=iOS Simulator,id=$A" \
  -derivedDataPath "$DD" >"$OUT/logs/build.log" 2>&1 && pass "build-for-testing" || { fail "build-for-testing (logs/build.log)"; exit 1; }
APP=$DD/Build/Products/Debug-iphonesimulator/PhotoShare.app
setup_sim() { boot "$1"; xcrun simctl install "$1" "$APP"; xcrun simctl privacy "$1" grant photos "$BUNDLE"; }
REC_PID=""
rec_start() { xcrun simctl io "$1" recordVideo --codec h264 --force "$OUT/videos/$2.mp4" >"$OUT/logs/rec-$2.log" 2>&1 & REC_PID=$!; sleep 1; }
rec_stop()  { [ -n "$REC_PID" ] && { kill -INT "$REC_PID" 2>/dev/null; wait "$REC_PID" 2>/dev/null; REC_PID=""; }; }
shot() { xcrun simctl io "$1" screenshot "$OUT/screens/$2.png" >/dev/null 2>&1; }
uistep() { # persona udid step [env...]
  local who=$1 udid=$2 step=$3; shift 3
  env TEST_RUNNER_VERIFY_EMAIL="$who@test.local" TEST_RUNNER_VERIFY_PASSWORD="$PASSWORD" \
      TEST_RUNNER_VERIFY_SUPABASE_URL="$API_URL" TEST_RUNNER_VERIFY_SUPABASE_ANON_KEY="$ANON_KEY" "$@" \
    xcodebuild test-without-building -project PhotoShare.xcodeproj -scheme PhotoShare \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DD" \
      -only-testing:PhotoShareUITests/ScenarioTests/$step -resultBundlePath "$OUT/logs/$who-$step.xcresult" \
      >"$OUT/logs/$who-$step.log" 2>&1
  local rc=$?; shot "$udid" "$who-$step"; return $rc; }
open_when_ready() { # udid url readyfile : fire `simctl openurl` once the UI test says it is signed in and waiting
  ( for _ in $(seq 1 180); do [ -f "$3" ] && break; sleep 1; done; sleep 2; xcrun simctl openurl "$1" "$2" ) & }

# ---- 1. dan creates an invite -------------------------------------------------------------------------
setup_sim "$A"; rec_start "$A" 1-dan-creates-invite
uistep dan "$A" testCreateInvite TEST_RUNNER_VERIFY_OUT_FILE="$OUT/logs/invite-link.txt"; check "dan: Add Friend shows an invite link (UI)" $?
rec_stop
CODE=$(psql_q "select code from invites where inviter_id='$DAN' order by created_at desc limit 1")
UI_LINK=$(cat "$OUT/logs/invite-link.txt" 2>/dev/null)
[ -n "$CODE" ] && [ "$UI_LINK" = "photoshare://invite/$CODE" ]; check "invite link in UI == invites row in DB (photoshare://invite/${CODE:0:8}…)" $?
xcrun simctl shutdown "$A"

# ---- 2. carol opens the link with simctl openurl and accepts -------------------------------------------
setup_sim "$B"; rec_start "$B" 2-carol-accepts-via-deep-link
rm -f "$OUT/logs/carol-ready"
open_when_ready "$B" "$UI_LINK" "$OUT/logs/carol-ready"
uistep carol "$B" testAcceptInviteViaDeepLink TEST_RUNNER_VERIFY_EXPECT_NAME=Dan TEST_RUNNER_VERIFY_READY_FILE="$OUT/logs/carol-ready"
check "carol: simctl openurl -> accept screen names Dan -> Accept -> Dan in her Friends tab (UI)" $?
rec_stop
psql_q "select user_id, friend_id, send_enabled, receive_enabled from friendships order by 1,2" > "$OUT/db/friendships-after-accept.txt"
[ "$(fr "$DAN" "$CAROL")" = 11 ] && [ "$(fr "$CAROL" "$DAN")" = 11 ]; check "DB: dan<->carol friendship exists, Send+Receive ON on both sides" $?
[ "$(psql_q "select accepted_by from invites where code='$CODE'")" = "$CAROL" ]; check "DB: invite consumed by carol" $?

# ---- 3. negatives ----------------------------------------------------------------------------------------
out=$(rpc alice accept_invite "{\"p_code\":\"$CODE\"}"); echo "$out" | grep -q invite_used; check "API: a used invite cannot be accepted again (alice) -> invite_used" $?
NEW=$(rpc dan create_invite | tr -d '"')
out=$(rpc dan accept_invite "{\"p_code\":\"$NEW\"}"); echo "$out" | grep -q invite_self; check "API: dan cannot accept his own invite -> invite_self" $?
out=$(rpc alice accept_invite '{"p_code":"nope"}'); echo "$out" | grep -q invite_unknown; check "API: unknown code -> invite_unknown" $?
psql_q "update invites set expires_at = now() - interval '1 day' where code='$NEW'" >/dev/null
out=$(rpc alice accept_invite "{\"p_code\":\"$NEW\"}"); echo "$out" | grep -q invite_expired; check "API: expired invite -> invite_expired" $?
rm -f "$OUT/logs/carol-ready2"; rec_start "$B" 3-carol-opens-used-link
open_when_ready "$B" "$UI_LINK" "$OUT/logs/carol-ready2"
uistep carol "$B" testInviteLinkShowsProblem TEST_RUNNER_VERIFY_READY_FILE="$OUT/logs/carol-ready2" TEST_RUNNER_VERIFY_EXPECT_TEXT="already been used"
check "carol: reopening the used link explains it was already used (UI)" $?
rec_stop
xcrun simctl shutdown "$B"

# ---- 4. dan turns Receive OFF for carol --------------------------------------------------------------------
boot "$A"; rec_start "$A" 4-dan-turns-receive-off
uistep dan "$A" testSetFriendToggle TEST_RUNNER_VERIFY_FRIEND=Carol TEST_RUNNER_VERIFY_TOGGLE=receive TEST_RUNNER_VERIFY_VALUE=off
check "dan: Carol -> Receive OFF (UI)" $?
rec_stop
[ "$(fr "$DAN" "$CAROL")" = 10 ] && [ "$(fr "$CAROL" "$DAN")" = 11 ]; check "DB: dan.receive=false for carol, dan.send and carol's toggles untouched" $?
xcrun simctl shutdown "$A"

# ---- 5. carol sees Paused; server enforcement ---------------------------------------------------------------
boot "$B"; rec_start "$B" 5-carol-paused-then-send-off
uistep carol "$B" testFriendRowStatus TEST_RUNNER_VERIFY_EXPECT_STATUS="Paused"
check "carol: Dan row says Paused (her Send is ON but Dan's Receive is OFF) (UI)" $?
deliver() { # persona(sender) recipient_id -> HTTP code of the photo_recipients insert; echoes it
  local t pid; t=$(token "$1")
  pid=$(curl -s -X POST "$API_URL/rest/v1/photos" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
    -H 'Prefer: return=representation' -d "{\"sender_id\":\"$(id_of "$1")\",\"storage_path\":\"photos/x-$RANDOM.jpg\",\"taken_at\":\"2026-01-01T00:00:00Z\"}" | jq -r '.[0].id')
  curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/photo_recipients" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" \
    -H 'Content-Type: application/json' -d "{\"photo_id\":\"$pid\",\"recipient_id\":\"$2\"}"; }
code=$(deliver carol "$DAN"); [ "$code" = 403 ] || [ "$code" = 401 ]; check "RLS: carol -> dan delivery refused while dan's Receive is OFF (HTTP $code)" $?
rpc dan set_friend_prefs "{\"p_friend\":\"$CAROL\",\"p_receive\":true}" >/dev/null
code=$(deliver carol "$DAN"); [ "$code" = 201 ]; check "RLS: carol -> dan delivery allowed once dan's Receive is ON again (HTTP $code)" $?
uistep carol "$B" testSetFriendToggle TEST_RUNNER_VERIFY_FRIEND=Dan TEST_RUNNER_VERIFY_TOGGLE=send TEST_RUNNER_VERIFY_VALUE=off
check "carol: Dan -> Send OFF (UI)" $?
rec_stop
[ "$(fr "$CAROL" "$DAN")" = 01 ]; check "DB: carol.send=false, carol.receive=true" $?
code=$(deliver carol "$DAN"); [ "$code" = 403 ] || [ "$code" = 401 ]; check "RLS: carol -> dan delivery refused after carol turned Send OFF (HTTP $code)" $?
code=$(deliver dan "$CAROL"); [ "$code" = 201 ]; check "RLS: dan -> carol still allowed (toggles are independent per direction) (HTTP $code)" $?
psql_q "select sender_id, recipient_id from photo_recipients pr join photos p on p.id=pr.photo_id" > "$OUT/db/deliveries.txt"
xcrun simctl shutdown "$B"

# ---- 6. dan unfriends carol -------------------------------------------------------------------------------------
boot "$A"; rec_start "$A" 6-dan-unfriends
uistep dan "$A" testUnfriend TEST_RUNNER_VERIFY_FRIEND=Carol; check "dan: Carol -> Unfriend -> empty list (UI)" $?
rec_stop
[ "$(psql_q "select count(*) from friendships where user_id in ('$DAN','$CAROL') and friend_id in ('$DAN','$CAROL')")" = 0 ]; check "DB: both friendship rows removed (unilateral, immediate)" $?
[ "$(rpc carol list_friends)" = "[]" ]; check "API: carol's friends list is empty" $?
[ "$(psql_q "select count(*) from photos where sender_id in ('$DAN','$CAROL')")" -ge 2 ]; check "previously shared photos remain after unfriend" $?

for u in $A $B; do xcrun simctl shutdown "$u" 2>/dev/null; done
echo >> "$SUMMARY"; echo "Artifacts: screens/, videos/, logs/, db/ in $OUT" >> "$SUMMARY"
log "done: $FAILS failure(s). Summary: $SUMMARY"; cat "$SUMMARY"
exit $((FAILS>0))
