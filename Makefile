# Verification entry points. Run from the repo root.
#   make verify        build + unit tests + UI smoke on the simulator
#   make test-unit     unit tests only (incl. face-match pipeline)
#   make test-ui       UI tests only
#   make scenario-friends  invite link / deep link / accept / Send+Receive toggles / unfriend (2 sims, local Supabase)
#   make verify-friends-api  friends backend (invites, toggles, RLS) against local Supabase, no simulator
#   make scenario      2-persona e2e on simulators vs local Supabase (slow, ~10 min; needs Docker/colima)
SIM_NAME ?= iPhone 17 Pro
DEST     := platform=iOS Simulator,name=$(SIM_NAME)
OUT      := verification-output
XCB      := xcodebuild -project PhotoShare.xcodeproj -scheme PhotoShare -destination '$(DEST)' -derivedDataPath $(OUT)/DerivedData

.PHONY: scenario-friends verify-friends-api verify facematch generate test-unit test-ui scenario

generate:
	xcodegen generate

verify: generate facematch test-unit test-ui

# face matching on the Mac with real Vision landmarks (no Simulator): gates 0 false matches + full recall on the fixtures
facematch:
	scripts/verify/facematch-mac.sh --min-recall 114

test-unit: generate
	@mkdir -p $(OUT) && rm -rf $(OUT)/unit.xcresult
	TEST_RUNNER_VERIFY_OUTPUT_DIR=$(CURDIR)/$(OUT) $(XCB) -only-testing:PhotoShareTests -resultBundlePath $(OUT)/unit.xcresult test 2>&1 | tee $(OUT)/unit.log | tail -25

test-ui: generate
	@mkdir -p $(OUT) && rm -rf $(OUT)/ui.xcresult
	$(XCB) -only-testing:PhotoShareUITests/LaunchSmokeTests -resultBundlePath $(OUT)/ui.xcresult test 2>&1 | tee $(OUT)/ui.log | tail -25

scenario:
	scripts/verify/run_scenario.sh

scenario-friends:
	scripts/verify/run_friends_scenario.sh

verify-friends-api:
	scripts/verify/check_friends_api.sh
