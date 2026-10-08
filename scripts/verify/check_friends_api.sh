#!/usr/bin/env bash
# Fast, simulator-free check of the friends backend (invites, friendships, toggles, RLS) against LOCAL Supabase.
# Resets the database first (takes the shared lock). Usage: scripts/verify/check_friends_api.sh   (make verify-friends-api)
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/verify/simlock.sh; simlock_acquire   # db reset is exclusive too
FAILS=0
pass() { echo "PASS: $*"; }; fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
check() { if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; fi; }
psql_q() { docker exec supabase_db_photo-sharing-app psql -U postgres -At -c "$1"; }
docker info >/dev/null 2>&1 || { echo "docker not running"; exit 2; }
supabase status >/dev/null 2>&1 || supabase start -x studio,imgproxy,edge-runtime,logflare,vector,mailpit,realtime,supavisor,postgres-meta >/dev/null 2>&1
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
supabase db reset >/dev/null 2>&1 || { echo "db reset failed"; exit 1; }; sleep 5
token() { curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$1@test.local\",\"password\":\"Test1234!\"}" | jq -r .access_token; }
EMPTY_JSON='{}'
rpc() { curl -s -X POST "$API_URL/rest/v1/rpc/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $(token "$1")" -H 'Content-Type: application/json' -d "${3:-$EMPTY_JSON}"; }
id_of() { psql_q "select id from auth.users where email='$1@test.local'"; }
DAN=$(id_of dan); CAROL=$(id_of carol); ALICE=$(id_of alice); BOB=$(id_of bob)
fr() { psql_q "select send_enabled::int::text || receive_enabled::int::text from friendships where user_id='$1' and friend_id='$2'"; }
deliver() { local t pid; t=$(token "$1")
  pid=$(curl -s -X POST "$API_URL/rest/v1/photos" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
    -H 'Prefer: return=representation' -d "{\"sender_id\":\"$(id_of "$1")\",\"storage_path\":\"photos/x-$RANDOM.jpg\",\"taken_at\":\"2026-01-01T00:00:00Z\"}" | jq -r '.[0].id')
  curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/photo_recipients" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" \
    -H 'Content-Type: application/json' -d "{\"photo_id\":\"$pid\",\"recipient_id\":\"$2\"}"; }

[ "$(psql_q "select count(*) from friendships")" = 2 ] && [ "$(fr "$ALICE" "$BOB")" = 11 ]; check "seed: alice<->bob are friends, toggles ON" $?
code=$(deliver alice "$BOB"); [ "$code" = 201 ]; check "friends alice->bob can deliver (HTTP $code)" $?
code=$(deliver dan "$CAROL"); [ "$code" = 403 ] || [ "$code" = 401 ]; check "non-friends dan->carol cannot deliver (HTTP $code)" $?

CODE=$(rpc dan create_invite | tr -d '"'); [ "${#CODE}" = 32 ]; check "dan creates an invite (32-char code)" $?
rpc carol preview_invite "{\"p_code\":\"$CODE\"}" | jq -e '.[0].state=="valid" and .[0].inviter_name=="Dan"' >/dev/null; check "carol previews it: valid, inviter Dan" $?
rpc dan preview_invite "{\"p_code\":\"$CODE\"}" | jq -e '.[0].state=="self"' >/dev/null; check "dan previewing his own link: state=self" $?
[ "$(curl -s "$API_URL/rest/v1/invites?select=code" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $(token carol)")" = "[]" ]; check "carol cannot read dan's invites table directly" $?
rpc carol accept_invite "{\"p_code\":\"$CODE\"}" | grep -q "$DAN"; check "carol accepts -> returns dan's id" $?
[ "$(fr "$DAN" "$CAROL")" = 11 ] && [ "$(fr "$CAROL" "$DAN")" = 11 ]; check "both directions created, Send+Receive default ON" $?
rpc alice accept_invite "{\"p_code\":\"$CODE\"}" | grep -q invite_used; check "used invite refused (invite_used)" $?
rpc carol preview_invite "{\"p_code\":\"$CODE\"}" | jq -e '.[0].state=="used"' >/dev/null; check "preview of used invite: state=used" $?
N2=$(rpc dan create_invite | tr -d '"')
rpc dan accept_invite "{\"p_code\":\"$N2\"}" | grep -q invite_self; check "own invite refused (invite_self)" $?
rpc carol accept_invite "{\"p_code\":\"$N2\"}" | grep -q already_friends; check "already friends refused (already_friends)" $?
rpc carol preview_invite "{\"p_code\":\"$N2\"}" | jq -e '.[0].state=="already_friends"' >/dev/null; check "preview: already_friends" $?
rpc alice accept_invite '{"p_code":"nope"}' | grep -q invite_unknown; check "unknown code refused" $?
psql_q "update invites set expires_at = now() - interval '1 day' where code='$N2'" >/dev/null
rpc alice accept_invite "{\"p_code\":\"$N2\"}" | grep -q invite_expired; check "expired invite refused" $?

rpc carol list_friends | jq -e 'length==1 and .[0].display_name=="Dan" and .[0].my_send and .[0].their_receive' >/dev/null; check "list_friends(carol) = [Dan] with both sides' toggles" $?
rpc dan set_friend_prefs "{\"p_friend\":\"$CAROL\",\"p_receive\":false}" >/dev/null
[ "$(fr "$DAN" "$CAROL")" = 10 ] && [ "$(fr "$CAROL" "$DAN")" = 11 ]; check "dan Receive OFF changes only dan's row" $?
rpc carol list_friends | jq -e '.[0].their_receive==false and .[0].my_send==true' >/dev/null; check "carol sees their_receive=false (drives 'Paused')" $?
code=$(deliver carol "$DAN"); [ "$code" = 403 ] || [ "$code" = 401 ]; check "RLS: carol->dan refused while dan Receive OFF (HTTP $code)" $?
code=$(deliver dan "$CAROL"); [ "$code" = 201 ]; check "RLS: dan->carol still allowed (independent directions) (HTTP $code)" $?
rpc dan set_friend_prefs "{\"p_friend\":\"$CAROL\",\"p_receive\":true}" >/dev/null
code=$(deliver carol "$DAN"); [ "$code" = 201 ]; check "RLS: carol->dan allowed once Receive ON (HTTP $code)" $?
rpc carol set_friend_prefs "{\"p_friend\":\"$DAN\",\"p_send\":false}" >/dev/null
code=$(deliver carol "$DAN"); [ "$code" = 403 ] || [ "$code" = 401 ]; check "RLS: carol->dan refused after carol Send OFF (HTTP $code)" $?
rpc alice set_friend_prefs "{\"p_friend\":\"$DAN\",\"p_send\":false}" | grep -q not_friends; check "cannot set toggles for a non-friend" $?
[ "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$API_URL/rest/v1/friendships?user_id=eq.$CAROL" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $(token carol)" -H 'Content-Type: application/json' -d '{"send_enabled":true}')" != 204 ] \
  || [ "$(fr "$CAROL" "$DAN")" = 01 ]; check "clients cannot write friendships directly" $?

# Free-plan limit: Send ON for at most 3 friends. alice has bob; give her carol and dan (3 total), then try a 4th via a pro-less extra user.
psql_q "insert into friendships (user_id, friend_id, send_enabled) select '$ALICE', f, true from unnest(array['$CAROL','$DAN']::uuid[]) f on conflict do nothing;
        insert into friendships (user_id, friend_id) select f, '$ALICE' from unnest(array['$CAROL','$DAN']::uuid[]) f on conflict do nothing" >/dev/null
rpc alice set_friend_prefs "{\"p_friend\":\"$DAN\",\"p_send\":false}" >/dev/null
rpc alice set_friend_prefs "{\"p_friend\":\"$DAN\",\"p_send\":true}" | grep -q send_limit && fail "free user with 3rd Send was refused" || pass "free plan: 3rd Send allowed"
psql_q "update friendships set send_enabled=true where user_id='$ALICE'" >/dev/null
EXTRA=$(psql_q "insert into auth.users (instance_id,id,aud,role,email) values ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated','eve@test.local') returning id" | head -1)
psql_q "insert into friendships (user_id, friend_id, send_enabled) values ('$ALICE','$EXTRA',false),('$EXTRA','$ALICE',true)" >/dev/null
rpc alice set_friend_prefs "{\"p_friend\":\"$EXTRA\",\"p_send\":true}" | grep -q send_limit; check "free plan: 4th Send refused (send_limit)" $?
psql_q "update profiles set plan='pro' where id='$ALICE'" >/dev/null
rpc alice set_friend_prefs "{\"p_friend\":\"$EXTRA\",\"p_send\":true}" >/dev/null; [ "$(fr "$ALICE" "$EXTRA")" = 11 ]; check "pro plan: 4th Send allowed" $?

rpc dan unfriend "{\"p_friend\":\"$CAROL\"}" >/dev/null
[ "$(psql_q "select count(*) from friendships where user_id in ('$DAN','$CAROL') and friend_id in ('$DAN','$CAROL')")" = 0 ]; check "unfriend removes both rows" $?
[ "$(psql_q "select count(*) from photos where sender_id in ('$DAN','$CAROL')")" -ge 2 ]; check "shared photos remain after unfriend" $?
code=$(deliver carol "$DAN"); [ "$code" = 403 ] || [ "$code" = 401 ]; check "RLS: no delivery after unfriend (HTTP $code)" $?
echo; [ $FAILS = 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"; exit $((FAILS>0))
