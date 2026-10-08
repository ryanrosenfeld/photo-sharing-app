# Verification harness

```
make verify      # unit tests (face-match pipeline) + UI launch smoke test, ~2 min
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
