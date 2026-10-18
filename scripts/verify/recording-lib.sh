# Source me. Tight simulator recordings: only the part of a UI test where the test is actually running.
#
#   run_recorded <udid> <out.mp4> <log> <command...>
#     Records <udid> while <command> runs (output goes to <log>), stops recording as soon as the test case
#     reports passed/failed (xcodebuild itself can idle for minutes afterwards), then trims the leading
#     home-screen wait (before the test starts) and compresses. Returns the command's exit code.
#   join_clips <out.mp4> <clip.mp4...>   concatenates clips made by run_recorded into one walkthrough.
#
# Needs ffmpeg (brew install ffmpeg). Without it the raw recording is kept as <out.mp4>.
run_recorded() {
  local udid=$1 out=$2 log=$3; shift 3
  local raw="$out.raw.mp4" t0 started="" ended rc
  mkdir -p "$(dirname "$out")"
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$raw" >/dev/null 2>&1 & local rec=$!
  t0=$(date +%s); sleep 1
  "$@" >"$log" 2>&1 & local cmd=$!
  while kill -0 $cmd 2>/dev/null; do
    [ -z "$started" ] && grep -q "Test Case '.*' started" "$log" 2>/dev/null && started=$(date +%s)
    grep -qE "Test Case '.*' (passed|failed)" "$log" 2>/dev/null && break
    sleep 0.5
  done
  ended=$(date +%s); sleep 1
  kill -INT $rec 2>/dev/null; wait $rec 2>/dev/null
  wait $cmd; rc=$?
  if command -v ffmpeg >/dev/null 2>&1; then
    local ss=$(( ${started:-$t0} - t0 )); [ $ss -gt 1 ] && ss=$((ss - 1))   # keep the app launch, drop the home screen before it
    ffmpeg -loglevel error -y -ss "$ss" -t $(( ended - ${started:-$t0} + 3 )) -i "$raw" \
      -vf "scale=-2:1100,fps=15" -c:v libx264 -crf 30 -an -pix_fmt yuv420p -movflags +faststart "$out" && rm -f "$raw"
  else
    mv "$raw" "$out"
  fi
  return $rc
}

join_clips() {
  local out=$1; shift
  command -v ffmpeg >/dev/null 2>&1 || { echo "join_clips: ffmpeg missing" >&2; return 1; }
  local list; list=$(mktemp)
  for c in "$@"; do echo "file '$(cd "$(dirname "$c")" && pwd)/$(basename "$c")'" >> "$list"; done
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$list" -c copy -movflags +faststart "$out"; rm -f "$list"
}
