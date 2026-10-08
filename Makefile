# Verification entry points. Run from the repo root.
#   make verify        build + unit tests + UI smoke on the simulator
#   make test-unit     unit tests only (incl. face-match pipeline)
#   make test-ui       UI tests only
#   make scenario      2-persona e2e on simulators vs local Supabase (slow, ~10 min; needs Docker/colima)
SIM_NAME ?= iPhone 17 Pro
DEST     := platform=iOS Simulator,name=$(SIM_NAME)
OUT      := verification-output
XCB      := xcodebuild -project PhotoShare.xcodeproj -scheme PhotoShare -destination '$(DEST)' -derivedDataPath $(OUT)/DerivedData

.PHONY: verify generate test-unit test-ui scenario onboarding

generate:
	xcodegen generate

verify: generate test-unit test-ui

test-unit: generate
	@mkdir -p $(OUT) && rm -rf $(OUT)/unit.xcresult
	TEST_RUNNER_VERIFY_OUTPUT_DIR=$(CURDIR)/$(OUT) $(XCB) -only-testing:PhotoShareTests -resultBundlePath $(OUT)/unit.xcresult test 2>&1 | tee $(OUT)/unit.log | tail -25

test-ui: generate
	@mkdir -p $(OUT) && rm -rf $(OUT)/ui.xcresult
	$(XCB) -only-testing:PhotoShareUITests/LaunchSmokeTests -resultBundlePath $(OUT)/ui.xcresult test 2>&1 | tee $(OUT)/ui.log | tail -25

onboarding:
	scripts/verify/run_onboarding.sh

scenario:
	scripts/verify/run_scenario.sh
