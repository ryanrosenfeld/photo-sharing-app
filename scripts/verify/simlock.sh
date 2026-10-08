#!/bin/bash
# Usage: scripts/verify/simlock.sh <command...>
# Serialises Simulator runs across worktrees (mkdir lock), shuts simulators down afterwards.
LOCK=$HOME/dev/.photoshare-sim.lock.d
until mkdir "$LOCK" 2>/dev/null; do sleep 10; done
trap 'rmdir "$LOCK"; xcrun simctl shutdown all' EXIT
"$@"
