#!/usr/bin/env bash
# Run a command while holding the shared simulator lock (the MacBook Air thrashes with two sim users at once,
# and parallel workstreams share one local Supabase). Shuts down only the verify-alice/verify-bob devices afterwards (never `shutdown all`).
#   scripts/verify/with_sim_lock.sh make verify
LOCK=${PHOTOSHARE_SIM_LOCK:-/tmp/photoshare-sim.lock}
until mkdir "$LOCK" 2>/dev/null; do
  # reclaim a lock whose owner died
  owner=$(cat "$LOCK/pid" 2>/dev/null); [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null && rm -rf "$LOCK" && continue
  echo "[simlock] waiting for $(cat "$LOCK/who" 2>/dev/null || echo another run)…" >&2; sleep 15
done
echo $$ > "$LOCK/pid"; echo "${SIM_LOCK_WHO:-$(basename "$PWD"): $*}" > "$LOCK/who"
cleanup() { for n in verify-alice verify-bob; do xcrun simctl shutdown "$n" 2>/dev/null; done; rm -rf "$LOCK"; }
trap cleanup EXIT INT TERM
"$@"
