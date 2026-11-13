# Verification harness

```
make verify      # unit tests (face-match pipeline) + UI launch smoke test, ~2 min
make verify-friends-api  # friends backend (invites, toggles, RLS) against local Supabase, no simulator, ~1 min
make scenario-friends    # Dan invites Carol: invite link, simctl openurl deep link, accept, toggles, unfriend (2 sims), ~10 min
make sims-pair   # two sims side by side, signed in as Ryan + Bob on the local DB, no taps (see below)
make scenario    # Alice/Bob end-to-end on 2 simulators vs local Supabase, ~10 min
```

Prereqs: Xcode, `xcodegen`, `supabase` CLI, Docker via Colima (`brew install colima docker`, `colima start --cpu 2 --memory 4`).
A 16 GB MacBook Air thrashes if two simulators, Xcode and Docker all run hard, so the scenario boots one simulator at a time
(dedicated devices `verify-alice` / `verify-bob`, erased at the start of each run). Shut simulators down afterwards
(`xcrun simctl shutdown all`): the Photos analysis daemons that start after `addmedia` burn CPU.

## What the scenario checks
1. `supabase db reset` applies the repo migrations + `supabase/seed_personas.sql` (alice/bob/carol/dan @test.local, password `Test1234!`, local only).
2. Bob's face-profile photos are uploaded (API). Alice signs in (UI) and enrolls Bob from that profile (UI, on-device embeddings).
3. `simctl addmedia` puts a photo of Bob and a photo of Dan in Alice's library; Alice's app is relaunched with `simctl launch`.
4. DB asserts exactly 1 photo from Alice, 1 recipient (Bob), 1 storage object (Dan's photo was not uploaded).
5. Bob signs in on the second simulator and the Photos tab shows the photo (UI).

Evidence: `verification-output/scenario-<ts>/{summary.md,screens/,logs/,db/}` (gitignored). Not covered: push (`simctl push`, no APNs in the app yet) and `simctl openurl` (no friend-invite deep link yet).

## Fixtures
`PhotoShareTests/Fixtures/sources/*.jpg` are AI-generated portraits (SFHQ "Synthetic Faces High Quality", via the
`bitmind/SyntheticFacesHQ` Hugging Face preview rows); `make_fixtures.py` derives the test photos (pose/zoom/lighting variants,
an EXIF-rotated photo and a 4032x3024 frame). Re-run it after editing. Verify the SFHQ licence terms before any redistribution beyond this repo.

## Shared Mac etiquette
`scripts/verify/simlock.sh` takes `/tmp/photoshare-sim.lock` (pid inside, stale locks are cleared) so only one simulator/DB-reset run happens at a time across worktrees; every scenario script sources it and shuts simulators down on exit. `run_friends_scenario.sh` uses its own devices (`verify-friends-a/b`) and writes screenshots plus `simctl io recordVideo` clips to `verification-output/friends-<ts>/{screens,videos}`.

## Recordings
`recording-lib.sh` (`run_recorded`, `join_clips`) makes tight walkthrough videos: it records only while a UI test runs, stops when the test case reports passed/failed, cuts the home-screen wait before launch and compresses (needs ffmpeg). `run_onboarding.sh` (RECORD=0 to skip), `record_review_walkthrough.sh` and `record_photos_walkthrough.sh` use it and write one clip per step plus a joined video. Every scenario script passes `-collect-test-diagnostics never`: without it xcodebuild idled ~10 minutes after each UI test collecting simulator diagnostics.

## Side-by-side pair (`make sims-pair`)
`scripts/verify/sims_pair.sh` boots two named simulators on the newest iOS 27.x runtime that can host an iPhone 17 Pro (27.1 cannot on this Mac, so 27.0): `pair-me` signed in as `ME_EMAIL` (default `ryro003@gmail.com`) and `pair-friend` signed in as `FRIEND_EMAIL` (default `bob@test.local`, already Ryan's friend). It builds the current tree, installs it, grants Photos, then launches each with a one-off access/refresh token pair minted from the local auth admin API (magic-link exchange): no password, no UI taps, and no other session (e.g. Ryan's phone) is touched. The app consumes them in `AuthManager.loadSession` (DEBUG builds only, only when the sim has no session; afterwards the keychain keeps it). It then tiles the windows left/right with AppleScript when Simulator.app exists (needs Accessibility for the terminal); otherwise view them in the Claude desktop simulator panel.
- Never resets the database and never touches other simulators; takes the shared sim lock. Stop with `make sims-pair-down` (shuts down only these two).
- Options: `SKIP_BUILD=1`, `FRESH=1` (erase both sims first), `ME_EMAIL=`, `FRIEND_EMAIL=`, `RUNTIME=27.0`, `TILE=0`. Any local user works, e.g. `FRIEND_EMAIL=troy@example.com`.
- Both sims land on the notifications onboarding step ("not now"); there is no CLI way to pre-grant notifications.
