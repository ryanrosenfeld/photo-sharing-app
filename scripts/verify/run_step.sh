#!/usr/bin/env bash
# Run ONE ScenarioTests step on a persona's simulator (already provisioned by a scenario run) for fast debugging.
#   scripts/verify/with_sim_lock.sh scripts/verify/run_step.sh alice testSetManualReview [ENV=val ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
who=$1 step=$2; shift 2
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
udid=$(xcrun simctl list devices | grep "    verify-$who (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
xcrun simctl boot "$udid" 2>/dev/null; xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
env TEST_RUNNER_VERIFY_EMAIL="$who@test.local" TEST_RUNNER_VERIFY_PASSWORD='Test1234!' \
    TEST_RUNNER_VERIFY_SUPABASE_URL="$API_URL" TEST_RUNNER_VERIFY_SUPABASE_ANON_KEY="$ANON_KEY" "$@" \
  xcodebuild test -project PhotoShare.xcodeproj -scheme PhotoShare -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath verification-output/DerivedData -only-testing:PhotoShareUITests/ScenarioTests/$step 2>&1 | tee verification-output/run_step.log | grep -E "error:|Test Case|\*\* TEST"
