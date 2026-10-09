# Source me (library flavour of simlock.sh, same /tmp/photoshare-sim.lock). Serializes simulator/scenario runs across worktrees (the MacBook thrashes with two runs at once).
# Lock = directory /tmp/photoshare-sim.lock holding the owner's PID; released on exit (and simulators are shut down).
LOCK=/tmp/photoshare-sim.lock
simlock_acquire() {
  local waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    local owner; owner=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$LOCK"; continue; fi  # stale
    [ $((waited % 60)) = 0 ] && echo "[simlock] waiting for simulator lock held by pid ${owner:-?} (${waited}s)"
    sleep 5; waited=$((waited+5))
  done
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT   # callers shut down only their own devices (never shutdown all: other sessions share the Mac)
}
