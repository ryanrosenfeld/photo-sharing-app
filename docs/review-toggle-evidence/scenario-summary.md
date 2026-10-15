# Scenario run 20261015-020709
- PASS: db reset: migrations + personas applied
- PASS: persona sign-in via API (bob)
- PASS: Bob's face profile: 2 reference photos in storage
- PASS: personas marked as having a face profile (skips onboarding)
- PASS: build-for-testing
- PASS: alice sim: booted, app installed, Photos permission granted (simctl privacy)
- PASS: alice: sign in (UI)
- PASS: alice: enrolled Bob from his face profile (UI; embeddings computed on-device)
- PASS: alice: Friend Detail > Review before sending ON for Bob (global setting left OFF) (UI)
- PASS: alice: simctl addmedia (2 photos of Bob, 1 of Dan; bob_2 is also a reference photo, so it matches for sure)
- PASS: alice's phone matched and queued 2 photos of Bob for review (Dan's was ignored)
- PASS: NOTHING uploaded while queued: photos=0, storage objects=0
- PASS: alice: queue (2) survived relaunch; Send tapped on the first photo (UI)
- PASS: approve uploaded exactly 1 photo, to Bob
- PASS: alice: Discard tapped on the remaining photo; queue empty (UI)
- PASS: discard uploaded nothing: still photos=1, storage objects=1
- PASS: after relaunch the queue stays empty (rejected photos are not re-queued)
- PASS: alice: Friend Detail > Review before sending OFF for Bob (UI)
- PASS: review OFF for Bob: new photo of Bob auto-sent (photos=2), not queued
- PASS: queue empty after auto-send
- PASS: bob sim: booted, app installed
- PASS: bob: Photos tab shows the approved photo and the auto-sent one (2) from Alice (UI)

Artifacts: screens/, logs/, db/ in /Users/ryan/dev-personal/photoshare-review-toggle/verification-output/scenario-20261015-020709
