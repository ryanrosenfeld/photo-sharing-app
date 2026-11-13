#!/usr/bin/env bash
# Two iOS simulators side by side on this Mac, each signed in (no taps) against the LOCAL Supabase:
#   pair-me      -> Ryan   (ME_EMAIL,     default ryro003@gmail.com)
#   pair-friend  -> a friend (FRIEND_EMAIL, default bob@test.local, already Ryan's friend)
# Usage: scripts/verify/sims_pair.sh [up|down|status]      (make sims-pair / sims-pair-down)
#   env: ME_EMAIL FRIEND_EMAIL  accounts; SKIP_BUILD=1 reuse the last build; FRESH=1 erase both sims first;
#        RUNTIME=27.1 iOS runtime (default: newest iOS 27.x); DEVICE_TYPE=iPhone-17-Pro; TILE=0 skip window tiling.
# Never resets the database, never touches other simulators. Sessions come from the local auth admin API (magic-link token
# exchange), so no passwords are needed and nobody else's sessions are disturbed. Leaves both sims booted and tiled.
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/verify/simlock-lib.sh

BUNDLE=com.ryanrosenfeld.photoshare
ME_EMAIL=${ME_EMAIL:-ryro003@gmail.com}
FRIEND_EMAIL=${FRIEND_EMAIL:-bob@test.local}
DEVICE_TYPE=${DEVICE_TYPE:-iPhone-17-Pro}
STATE=$PWD/verification-output/sims-pair
DD=$PWD/verification-output/DerivedData
APP=$DD/Build/Products/Debug-iphonesimulator/PhotoShare.app
mkdir -p "$STATE"
log() { echo "[sims-pair $(date +%T)] $*"; }
die() { log "ERROR: $*"; exit 1; }

sim_udid() { # name -> udid, creating it on the newest iOS 27.x runtime that supports the device type if missing
  local u v; u=$(xcrun simctl list devices | grep "    $1 (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
  if [ -z "$u" ]; then
    for v in ${RUNTIME:-$(xcrun simctl list runtimes available | grep -oE 'iOS 27\.[0-9]+' | sed 's/iOS //' | sort -rV)}; do
      u=$(xcrun simctl create "$1" "com.apple.CoreSimulator.SimDeviceType.$DEVICE_TYPE" "com.apple.CoreSimulator.SimRuntime.iOS-${v//./-}" 2>/dev/null) && break
      u=""
    done
  fi
  [ -n "$u" ] || die "could not create $1 on any iOS 27 runtime"
  echo "$u"
}

cmd_down() {
  for n in pair-me pair-friend; do u=$(sim_udid "$n"); xcrun simctl shutdown "$u" 2>/dev/null; done
  log "shut down pair-me and pair-friend (nothing else)"
}
cmd_status() {
  xcrun simctl list devices | grep -E "pair-(me|friend)"
  for n in pair-me pair-friend; do echo "$n: $(xcrun simctl getenv "$(sim_udid $n)" HOME >/dev/null 2>&1 && echo booted || echo off)"; done
}

ensure_supabase() {
  docker info >/dev/null 2>&1 || die "docker is not running (start OrbStack/colima); not touching the database"
  if ! supabase status >/dev/null 2>&1; then
    log "starting local supabase (no reset)"
    supabase start -x studio,imgproxy,edge-runtime,logflare,vector,mailpit,realtime,supavisor,postgres-meta \
      >"$STATE/supabase-start.log" 2>&1 || die "supabase start failed ($STATE/supabase-start.log)"
  fi
  eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY|SERVICE_ROLE_KEY|SECRET_KEY)=')"
  SERVICE_KEY=${SERVICE_ROLE_KEY:-${SECRET_KEY:-}}
  [ -n "${API_URL:-}" ] && [ -n "$SERVICE_KEY" ] || die "could not read supabase status"
}

session_for() { # email -> "access refresh" via admin generate_link + verify (no password, other sessions untouched)
  local hashed; hashed=$(curl -s -X POST "$API_URL/auth/v1/admin/generate_link" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H 'Content-Type: application/json' \
    -d "{\"type\":\"magiclink\",\"email\":\"$1\"}" | jq -r '.hashed_token // empty')
  [ -n "$hashed" ] || die "no such user in local Supabase: $1"
  curl -s -X POST "$API_URL/auth/v1/verify" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"type\":\"magiclink\",\"token_hash\":\"$hashed\"}" | jq -r '"\(.access_token) \(.refresh_token)"'
}

write_secrets() { # Secrets.swift is gitignored but the build needs it; the app is pointed at local Supabase by launch env anyway
  [ -f PhotoShare/Config/Secrets.swift ] || cat > PhotoShare/Config/Secrets.swift <<SWIFT
enum Secrets {
    static let supabaseURL = "http://127.0.0.1:54321"
    static let supabaseAnonKey = "local"
    static let googleClientID = ""
}
SWIFT
}

boot() { xcrun simctl boot "$1" 2>/dev/null; xcrun simctl bootstatus "$1" -b >/dev/null 2>&1; }

launch_as() { # udid email
  local tok; tok=$(session_for "$2"); set -- "$1" "$2" ${tok% *} ${tok#* }
  [ -n "$3" ] && [ "$3" != null ] || die "could not mint a session for $2"
  xcrun simctl terminate "$1" "$BUNDLE" 2>/dev/null
  SIMCTL_CHILD_PHOTOSHARE_SUPABASE_URL="$API_URL" SIMCTL_CHILD_PHOTOSHARE_SUPABASE_ANON_KEY="$ANON_KEY" \
  SIMCTL_CHILD_PHOTOSHARE_ACCESS_TOKEN="$3" SIMCTL_CHILD_PHOTOSHARE_REFRESH_TOKEN="$4" \
    xcrun simctl launch "$1" "$BUNDLE" >/dev/null || die "launch failed on $1"
}

tile() { # side by side, left = me, right = friend, top-aligned on the main display
  [ "${TILE:-1}" = 0 ] && return
  open -Ra Simulator 2>/dev/null || { log "Simulator.app is not installed here, so there are no windows to tile; view the sims in the Claude desktop simulator panel (attach pair-me / pair-friend)"; return; }
  open -a Simulator --args -CurrentDeviceUDID "$ME"; sleep 2
  open -a Simulator --args -CurrentDeviceUDID "$FRIEND"; sleep 3
  osascript <<'OSA' 2>"$STATE/tile.log" || log "could not tile windows (grant Accessibility to your terminal app); drag them manually - see $STATE/tile.log"
tell application "System Events"
  tell process "Simulator"
    set wins to (every window whose title contains "pair-")
    set x to 0
    repeat with n in {"pair-me", "pair-friend"}
      repeat with w in wins
        if (name of w) contains n then
          set position of w to {x, 30}
          set x to x + (item 1 of (size of w)) + 10
        end if
      end repeat
    end repeat
  end tell
end tell
OSA
}

cmd_up() {
  simlock_acquire
  ensure_supabase
  write_secrets
  ME=$(sim_udid pair-me); FRIEND=$(sim_udid pair-friend)
  if [ "${FRESH:-0}" = 1 ]; then for u in $ME $FRIEND; do xcrun simctl shutdown "$u" 2>/dev/null; xcrun simctl erase "$u"; done; fi
  if [ "${SKIP_BUILD:-0}" != 1 ]; then
    command -v xcodegen >/dev/null && xcodegen generate >/dev/null
    log "building the current tree (a few minutes the first time)"
    xcodebuild build -project PhotoShare.xcodeproj -scheme PhotoShare -destination "platform=iOS Simulator,id=$ME" \
      -derivedDataPath "$DD" >"$STATE/build.log" 2>&1 || die "build failed (see $STATE/build.log)"
  fi
  [ -d "$APP" ] || die "no build at $APP"
  for u in $ME $FRIEND; do boot "$u"; xcrun simctl install "$u" "$APP"; xcrun simctl privacy "$u" grant photos "$BUNDLE"; done
  log "signing in: $ME_EMAIL on pair-me, $FRIEND_EMAIL on pair-friend"
  launch_as "$ME" "$ME_EMAIL"; launch_as "$FRIEND" "$FRIEND_EMAIL"
  tile
  log "ready. pair-me=$ME ($ME_EMAIL)  pair-friend=$FRIEND ($FRIEND_EMAIL). Stop with: make sims-pair-down"
}

case "${1:-up}" in up) cmd_up ;; down) cmd_down ;; status) cmd_status ;; *) die "usage: $0 [up|down|status]" ;; esac
