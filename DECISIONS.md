# PhotoShare — Decision Log

A record of significant architectural and product decisions. Add an entry whenever a non-obvious choice is made: include date, alternatives considered, reasoning, and trade-offs accepted.

---

### 2026-10-08 — Face matching: landmark alignment, cosine distance, pyramid detection

**Decision:** Align faces with Vision landmarks onto the ArcFace template, compare with cosine distance (threshold 0.55), detect over a tile pyramid, and penalise unaligned (box-crop) faces by 0.2.

**Alternatives considered:** keep box crop and just retune the Euclidean threshold (LFW: recall 75% only with 1.8% false matches, no usable threshold); flip test-time augmentation (+0.4% recall, 2x CoreML cost, dropped); wider/narrower box padding (0.25 was already best).

**Reasoning:** On 70 real LFW identities the old pipeline had AUC 0.979 and no threshold with both high recall and no wrong-person matches; aligned + cosine has AUC 1.000, 95% recall and 0 false matches in 18,009 wrong-person pairs. Alignment alone with the old Euclidean threshold collapsed recall to 3% because embedding length varies with image quality. Vision misses faces under ~5% of the frame, so tiles recover 80px heads in 12 MP photos. Full numbers and caveats: `docs/face-matching/README.md`.

**Trade-offs accepted:** Vision landmarks don't work in the Simulator, so Simulator tests cover only the fallback path and alignment is verified on the Mac, not yet on a physical iPhone. Pyramid detection costs up to ~27 Vision calls per 12 MP photo. Existing enrollments are invalidated (`face_enrollment_v3_`). Threshold chosen on LFW (easy) so real phone photos may need re-tuning.

### 2026-10-08 — Friends v3 implementation: invites + two-row friendships behind RPCs (diverges from the planned schema)

**Decision:** Ship the mutual-friendship model now with a smaller schema than ARCHITECTURE.md's E2E plan:
- `invites(code, inviter_id, expires_at, accepted_by, accepted_at)`: single-use link `photoshare://invite/<32-hex code>`, 14-day expiry.
- `friendships(user_id, friend_id, send_enabled, receive_enabled)`: **two directional rows per friendship, each owned by one user**, holding that user's Send and Receive toggles for the other. Replaces the planned `friendships` + `send_toggles` + `receive_toggles` trio.
- Clients never write these tables. All changes go through SECURITY DEFINER RPCs (`create_invite`, `preview_invite`, `accept_invite`, `list_friends`, `set_friend_prefs`, `unfriend`).
- `photo_recipients` INSERT policy now requires `can_share_with(sender, recipient)`: friends, sender Send ON, recipient Receive ON. So Receive OFF is enforced by the server, not just by the sender's app.
- The old `links` table is left in place (deprecated) and backfilled into friendships; migrations stay additive.

**Alternatives considered:** (1) the spec's pending-friendship row created by the inviter, then activated by the invitee: needs a pending state, cleanup of abandoned rows and realtime to finish the handshake, while the invite row already records the inviter's consent. (2) One row per pair with four booleans: simpler joins but each user's toggles live in columns the other user would need write access to.

**Reasoning:** An invite is the inviter's consent; accepting is the invitee's. A single atomic RPC creates both rows, so there is no half-friendship state. Per-user rows make "I only change my own toggles" a property of the RPC rather than column-level policy. The paused indicator ("my Send is ON but their Receive is OFF") needs the friend's Receive value, so `list_friends` returns both sides.

**Free-plan limit:** Send ON for at most 3 friends is checked in `set_friend_prefs`; `accept_invite` defaults Send to OFF if the accepting free user is already at the limit.

**Not done yet (deliberately):** push notifications for "[Name] accepted" (no APNs in the app; the inviter sees the friend on next foreground/refresh), E2E-encrypted reference photos and automatic enrollment on acceptance (the Enroll button stays), manual review queue.

**Trade-off accepted:** `list_friends` exposes a friend's Receive toggle to the sender. The spec calls Receive OFF "silent to sender" but also requires the paused indicator; the indicator won out.

---

### 2026-04-25 — Backend: Supabase over Firebase

**Decision:** Use Supabase (PostgreSQL) as the backend.

**Alternatives considered:** Firebase (Firestore), AWS Amplify.

**Reasoning:**

- The friend graph is inherently relational. PostgreSQL handles directional edges, RLS, and join-based access control naturally. Firestore would require awkward denormalization.
- Supabase is open-source and self-hostable, reducing vendor lock-in.
- Predictable compute-based pricing vs. Firestore's per-read/write model, which can spike in a photo-sharing workload.

**Trade-off accepted:** Firebase's FCM is more mature for push. Mitigated by going direct to APNs via Supabase Edge Functions.

---

### 2026-04-25 — Push Notifications: APNs direct over FCM / OneSignal

**Decision:** Send push notifications directly to APNs from Supabase Edge Functions.

**Alternatives considered:** FCM, OneSignal, Novu.

**Reasoning:**

- Keeps entire backend in one place.
- APNs HTTP/2 API is straightforward for a single notification type.
- Zero per-notification cost.
- FCM reintroduces a Google dependency.

**Trade-off accepted:** We own token registration and retry logic. Acceptable for the control gained.

---

### 2026-04-25 — Removed in-app camera; switched to photo library monitoring

**Decision:** Monitor native camera roll for new photos rather than providing an in-app camera.

**Reasoning:**

- Zero friction — users use their normal camera app.
- Simplifies app surface area.
- Photos processed on next app foreground (background processing is v2).

**Trade-off accepted:** Delay between capture and share bounded by next app open.

---

### 2026-04-25 — Merged Inbox into Photos tab; moved friend requests to Friends tab

**Decision:** Single Photos tab for received photos. Friend requests surface in Friends tab (badged).

**Reasoning:** Photos tab is focused on reviewing and saving received photos. Friend requests are relationship-management actions; Friends is the natural home.

---

### 2026-04-28 — Face recognition: MobileFaceNet (CoreML) over VNGenerateImageFeaturePrintRequest

**Decision:** Bundle MobileFaceNet CoreML model (`w600k_mbf`, ArcFace-trained) for face identity embeddings. Vision used for detection only.

**Alternatives considered:** `VNGenerateImageFeaturePrintRequest`, FaceNet via CoreML, Create ML, ARKit/TrueDepth.

**Reasoning:**

- `VNGenerateImageFeaturePrintRequest` is general-purpose image similarity, not face identity. Same-person and different-person distance distributions overlapped — no clean threshold.
- MobileFaceNet trained with ArcFace loss maximizes margin between identities. ~4MB, ~25ms on A-series.
- Apple has no public face identity API (`PersonsUI` is private).
- Create ML classifiers require a fixed set of people — incompatible with open-set per-friendship enrollment.

**Implementation notes:**

- Pipeline: detect bounding box → crop (25% padding) → resize 112×112 → CoreML → 512-D `[Float]`
- Downsample to 1024px before processing (full-res OOMs device)
- Embeddings stored under `face_enrollment_v2_` UserDefaults key prefix
- Model at `PhotoShare/Resources/MobileFaceNet.mlpackage`; conversion reproducible via `scripts/convert_mobilefacenet.py`
- Debug sandbox: Profile → Debug → Face Match Sandbox (debug/TestFlight only)

**Trade-off accepted:** Embeddings not L2-normalized; raw Euclidean distances in ~5–25 range. Threshold empirically tuned.

---

### 2026-05-05 — Friend model: mutual friendship + per-friend Send/Receive toggles

**Decision:** Replace directional link model (separate A→B and B→A link rows) with a single mutual `friendships` row plus per-user `send_toggles` and `receive_toggles` rows.

**Alternatives considered:** Retaining directional links; asymmetric follow model (Instagram-style).

**Reasoning:**

- Mutual friendship is a simpler mental model — one friend request, one acceptance.
- Directionality is preserved via independent Send/Receive toggles per user per friendship, giving the same flexibility as the old model.
- A photo flows A→B only if A's send_toggle is ON and B's receive_toggle (for A) is ON — either user can stop flow unilaterally.
- Removes the confusing "reverse link request" prompt from the old spec.
- Simpler schema: one `friendships` row vs. two `links` rows per pair.

**Trade-off accepted:** Toggle state visibility requires slightly more complex queries (join friendships → send_toggles → receive_toggles for the other user). Acceptable.

---

### 2026-05-05 — Friend discovery: invite link only (no in-app search, no contacts sync)

**Decision:** Friend requests initiated exclusively via generated invite link shared out-of-band (iMessage, WhatsApp, etc.). No in-app user search, no contacts sync for v1.

**Alternatives considered:** In-app profile search, contacts sync to surface existing users.

**Reasoning:**

- Invite-only naturally prevents unsolicited friend requests — no blocking needed for v1.
- Invite link is a growth mechanic: every invite is a touchpoint in a familiar channel.
- Simpler to build and a smaller privacy surface (no searchable user directory).

**Future:** Camera roll face clustering as a v2 cold-start/discovery mechanic — app surfaces faces that appear frequently in your camera roll and prompts you to invite them.

---

### 2026-05-05 — End-to-end encryption for shared photos

**Decision:** All shared photos are encrypted on the sender's device before upload. Server stores encrypted blobs it cannot decrypt.

**Alternatives considered:** Server-side encryption at rest (standard S3-style), P2P delivery (WebRTC), expiring signed URL relay.

**Reasoning:**

- Server-side encryption at rest still allows the server (and anyone who breaches it) to access photo content. Not acceptable for a privacy-first app.
- P2P requires both devices online simultaneously; no reliable fallback.
- E2E encryption with asymmetric keypairs (P-256 via CryptoKit) is the established pattern (Signal, iMessage). Server is a dumb encrypted blob store.
- Strongly differentiates on privacy: "We literally cannot see your photos."

**Implementation:** ECIES encryption via CryptoKit. Private key in Keychain + iCloud Keychain sync. Public key in `profiles` table. Encrypt to recipient public key at send time; decrypt on recipient device.

**Trade-off accepted:** Server metadata (sender ID, recipient ID, timestamp) is not encrypted — disclosed in privacy policy. Key recovery on total device loss requires iCloud Keychain (not zero-knowledge, but pragmatic for v1).

---

### 2026-05-05 — End-to-end encryption for face reference photos (symmetric key + per-friend wrapping)

**Decision:** Face reference photos encrypted on-device with a per-user AES-256-GCM symmetric key before upload. Symmetric key stored on server wrapped (encrypted) to each authorized friend's public key. Server cannot decrypt photos or keys.

**Alternatives considered:**

- Unencrypted server storage with strong access controls (simpler, but server can see biometric data)
- Per-friend asymmetric encryption of reference photos (requires re-upload for each new friend — expensive)
- P2P photo exchange via invite link (elegant but no automatic update propagation when user updates reference photos)

**Reasoning:**

- Symmetric key + per-friend wrapping is the standard pattern for E2E encrypted group content (analogous to Signal's sender keys). Encrypt once, distribute key to N friends.
- Solves the update propagation problem: when user updates reference photos, they re-encrypt with a new symmetric key and push new wrapped copies to all friends. Friends' devices auto-regenerate embeddings on next sync.
- Server stores only ciphertext — cannot perform any face analysis even under compulsion.
- Removes the privacy concern that previously made face profile opt-in; with E2E encryption, face profile can be required.

**Key distribution flow:** On friendship acceptance, each user's device wraps the other's symmetric key to their own public key and pushes to `friendship_keys`. Requires both devices to come online after acceptance (triggered by Supabase realtime). On unfriend, `friendship_keys` rows deleted server-side; RLS revokes bucket read access.

**Trade-off accepted:** Key wrapping on friendship acceptance requires both devices to be online. If a device is offline, key exchange is deferred until next foreground. During this window, enrollment is pending. Acceptable for v1.

---

### 2026-05-05 — Face profile: required, not opt-in

**Decision:** Face profile setup (uploading encrypted reference photos of yourself) is a hard-gated, mandatory onboarding step. Cannot send or accept a friend request without it.

**Alternatives considered:** Opt-in (previous spec); required-but-deferrable (prompt at first friend request).

**Reasoning:**

- With E2E encryption of reference photos, the primary privacy objection to mandatory face profile (server holds your biometric data in the clear) is resolved.
- Manual enrollment (sender picks photos of friend) is removed entirely — automatic enrollment via encrypted face profiles is the only path. This only works universally if everyone has a face profile.
- Required-but-deferrable creates a broken state: friendship accepted but enrollment can't complete because one user hasn't uploaded reference photos. Simpler to hard-gate upfront.
- Selfies are low-friction to select; the onboarding step is fast.

**Enforcement:** Client-side onboarding gate (cannot proceed past face profile step) + server-side Edge Function validates `face_profile_keys` row exists before setting `friendships.status = active`.

**Trade-off accepted:** Higher onboarding drop-off risk vs. deferrable setup. Mitigated by clear value framing ("So friends can find you in their photos") and a fast, focused UI. No migration concern for v1 (greenfield).

---

### 2026-05-05 — Manual review mode

**Decision:** Optional per-friend or global setting that queues matched photos locally for user approval before any upload occurs.

**Reasoning:**

- Auto-sharing is powerful but some users will want control over specific friendships (e.g. coworkers vs. close friends).
- Queuing locally means rejected photos never touch the server — a meaningful privacy property worth surfacing.
- Per-friend override allows fine-grained control without disabling the feature globally.

**Implementation:** Queue stored on-device only. `manual_review` table stores the setting (global flag in `profiles` or `UserDefaults`; per-friend flag in `manual_review` table). No server involvement until approval.

---

### 2026-05-05 — Brand reskin: PhotoShare → otto

**Decision:** Complete visual rebrand from "PhotoShare" to "otto" (lowercase), with the Otto the otter mascot, cream/sage color palette, and Georgia serif headings.

**Design source:** Claude Design session exported as `otto-photo-sharing` bundle. Final designs in `Otto Final.html`. Key choices from that session:
- App name: "otto" (lowercase)
- Color palette: canvas #F5EDDD, sage #5A8A6B, ink #1A2A1F, wax #C8543A
- Typography: Georgia (serif) for headings/taglines (often italic), SF Pro for UI
- Photos tab: Polaroid stack grouped by sender, swipe to advance
- Mascot: 4 PNG illustrations (hero, floating, sleeping, friends) with transparent backgrounds
- App icon: Polaroid variant
- Onboarding: 6-step flow; profile + reference photos merged into step 4

**Implementation:**
- `PhotoShare/Theme/OttoTheme.swift` — design tokens, color helpers, shared components
- `PhotoShare/Assets.xcassets/` — mascot PNGs + AppIcon placeholder
- All views reskinned; data/networking logic unchanged

**Trade-off accepted:** Custom tab bar uses `.page` TabView style (simpler implementation). Some design details (Friend Detail flow diagram, Review Queue screen) deferred to future iteration.

---

### 2026-04-25 — Auth: Apple + Google + Email/Password (phone number dropped)

**Decision:** Support Sign in with Apple, Sign in with Google, and email/password. Phone number auth dropped.

**Reasoning:**

- App Store guideline requires Sign in with Apple if any third-party OAuth is offered.
- Google is the most common OAuth provider.
- Email/password for users who prefer it.
- Phone number auth (original spec) dropped: higher friction, SMS cost, no meaningful benefit over email for early-stage.

**Note:** Original spec used phone number as the primary identity anchor for friend discovery. With invite-link-only discovery, phone number is no longer needed for that purpose.
