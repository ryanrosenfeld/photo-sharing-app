#!/bin/bash
# Usage: scripts/verify/simlock.sh <command...>
# Project-wide Simulator lock (/tmp/photoshare-sim.lock, pid inside): serialises Simulator runs across worktrees.
# Shuts down only the device named by $SIM_NAME afterwards, never other workstreams' devices.
LOCK=/tmp/photoshare-sim.lock
until mkdir "$LOCK" 2>/dev/null; do
  # reclaim a lock whose owner died
  if [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid")" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
  sleep 10
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"; [ -n "$SIM_NAME" ] && xcrun simctl shutdown "$SIM_NAME" 2>/dev/null' EXIT
"$@"
