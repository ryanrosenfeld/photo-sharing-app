# PhotoShare — Architecture v2

## Overview

iOS-only SwiftUI app backed by Supabase (database, auth, storage) and Apple Push Notification service (APNs) for delivery. Face detection and recognition run entirely on-device — Vision for detection, a bundled MobileFaceNet CoreML model for identity embeddings. All shared photos and face reference photos are end-to-end encrypted; the server stores only encrypted blobs it cannot read.

---

## Tech Stack

| Layer                   | Technology                                     | Notes                                                                                            |
| ----------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| UI                      | SwiftUI                                        | iOS 17+ deployment target                                                                        |
| Language                | Swift 6                                        | Strict concurrency enabled                                                                       |
| Backend / DB            | Supabase (PostgreSQL)                          | Hosted                                                                                           |
| Auth                    | Supabase Auth                                  | Apple, Google, email/password                                                                    |
| File Storage            | Supabase Storage                               | Encrypted photo blobs + encrypted face reference photo blobs                                     |
| Push Notifications      | APNs (direct)                                  | Via Supabase Edge Functions                                                                      |
| Face Detection          | Apple Vision (on-device)                       | `VNDetectFaceRectanglesRequest` for bounding boxes                                               |
| Face Recognition        | MobileFaceNet via CoreML                       | Bundled `.mlpackage`; 512-D ArcFace embeddings; on-device only                                   |
| Photo Encryption        | Asymmetric per-user keypair                    | Private key in Keychain + iCloud Keychain sync; encrypt to recipient public key at send time     |
| Face Profile Encryption | Symmetric key + per-friend asymmetric wrapping | Reference photos encrypted with symmetric key; symmetric key wrapped to each friend's public key |
| Project Generation      | XcodeGen                                       | `project.yml` is source of truth                                                                 |
| Package Manager         | Swift Package Manager                          |                                                                                                  |

---

## Project Structure

```
photo-sharing-app/
├── project.yml                    # XcodeGen config — edit this, not the .xcodeproj
├── SPEC.md                        # Product spec
├── ARCHITECTURE.md                # This file
├── CLAUDE.md                      # Instructions for Claude sessions
├── Secrets.template.swift         # Copy → PhotoShare/Config/Secrets.swift and fill in
├── .gitignore
├── scripts/
│   └── convert_mobilefacenet.py   # ONNX → CoreML conversion for the face model (one-time)
└── PhotoShare/
    ├── PhotoShareApp.swift         # @main entry point; wires auth URL handlers
    ├── ContentView.swift           # Root router: loading → auth → onboarding → main app
    ├── Config/
    │   ├── Secrets.swift           # Gitignored; holds API keys
    │   └── SupabaseClient.swift    # Global `supabase` singleton
    ├── Auth/                       # Apple / Google / Email auth flow
    ├── Crypto/
    │   ├── KeyPairManager.swift    # Keypair generation, Keychain storage, iCloud Keychain sync, public key upload
    │   ├── PhotoEncryption.swift   # Encrypt/decrypt photo blobs to/from recipient public key
    │   └── FaceProfileCrypto.swift # Symmetric key generation, per-friend key wrapping, encrypt/decrypt reference photos
    ├── Review/                          # Manual review mode
    │   ├── ReviewSettings.swift         # Global + per-friend override policy (pure, unit-tested)
    │   ├── ReviewQueueStore.swift       # On-device queue (JSON in Application Support, per user) + approve/reject
    │   ├── ReviewQueueView.swift        # Sheet opened from the Friends tab
    │   └── ShareUploader.swift          # The only code path that uploads a photo (auto-send and approve)
    ├── FaceMatch/
    │   ├── FaceDetector.swift              # Vision face detection + MobileFaceNet embedding
    │   ├── FaceEnrollmentStore.swift       # JSON persistence for [[Float]] embeddings per friend
    │   ├── FaceProfileSetupView/VM.swift   # Required onboarding step: select + upload encrypted reference photos
    │   ├── FaceProfileManager.swift        # Manages encrypted reference photo upload, symmetric key, per-friend key distribution
    │   ├── FaceEnrollmentSync.swift        # On friendship acceptance: fetch + decrypt friend's reference photos → generate embeddings → discard photos
    │   ├── PhotoLibraryManager.swift       # Camera roll cursor + permissions
    │   ├── AutoShareProcessor.swift        # End-to-end loop: detect → match → encrypt → upload
    │   └── FaceMatchSandboxView/VM.swift   # Debug-only screen for tuning the matcher
    ├── Resources/
    │   └── MobileFaceNet.mlpackage         # Bundled CoreML face recognition model
    └── Main/
        ├── MainTabView.swift               # Tab shell (Photos / Friends / Profile)
        ├── Photos/                         # Received photos feed, bulk save, expiry warnings
        ├── Friends/                        # Friends list, toggles, friend requests, manual review queue
        └── Profile/                        # Account, reference photos, plan status, settings
```

---

## Auth Flow

```
App launch
  └─ ContentView checks AuthManager.session
       ├─ loading    → ProgressView
       ├─ nil        → WelcomeView → AuthView
       │                  ├─ Sign in with Apple  (native ASAuthorization → Supabase idToken)
       │                  ├─ Sign in with Google (GIDSignIn → Supabase idToken)
       │                  └─ Email / Password    → EmailAuthView → Supabase signIn/signUp
       └─ present    → check onboarding completion flag
                           ├─ incomplete → OnboardingFlow
                           │                  1. Profile setup
                           │                  2. Face profile setup (required — hard gate)
                           │                  3. Photo Library permission
                           │                  4. First friend prompt
                           │                  5. Notifications permission
                           └─ complete   → MainTabView
```

- Apple Sign In uses a SHA-256 nonce for replay protection (required by Supabase)
- Google Sign In uses the native GIDSignIn SDK; token passed directly to Supabase
- Supabase `authStateChanges` async stream keeps `AuthManager.session` live
- Keypair is generated silently during auth (step 2 of onboarding), stored in Keychain with iCloud Keychain sync enabled; public key uploaded to `profiles` table

---

## Data Model

See `supabase/migrations/` for the full schema with RLS policies.

```
profiles           id (→ auth.users), display_name, avatar_url, plan (free|pro),
                   public_key (base64 DER — user's asymmetric public key)

friendships        id, requester_id, recipient_id, status (pending|active|declined)
                   unique(requester_id, recipient_id) — one row per pair, requester is lower UUID by convention

friendship_keys    friendship_id, user_id, encrypted_symmetric_key (base64)
                   — stores each user's copy of the other's face profile symmetric key, wrapped to their public key
                   — two rows per active friendship (one per direction)

send_toggles       friendship_id, user_id, enabled (bool, default true)
                   — whether this user is sending photos to the other person in this friendship

receive_toggles    friendship_id, user_id, enabled (bool, default true)
                   — whether this user is accepting photos from the other person in this friendship

manual_review      friendship_id, user_id, enabled (bool, default false)
                   — per-friend manual review override; global setting lives in profiles or UserDefaults

photos             id, sender_id, storage_path, taken_at, location_lat/lng, expires_at
                   — storage_path points to encrypted blob in `photos` bucket

photo_recipients   (photo_id, recipient_id) PK, delivered_at, viewed_at

device_tokens      id, user_id, apns_token (unique)

face_profile_keys  user_id PK, encrypted_symmetric_key (base64)
                   — user's own copy of their face profile symmetric key, wrapped to their own public key
                   — separate from friendship_keys; allows user to re-derive key on new device
```

**Supabase Storage buckets:**

- `photos` — encrypted shared photo blobs at path `{sender_id}/{photo_id}`; service-role write only; recipient read via signed URL
- `face-profiles` — encrypted face reference photo blobs at path `{user_id}/{uuid}`; owner write only; friend read gated by RLS (friendship must be active)

**Key RLS rules:**

- `friendships` INSERT: free tier limit of 3 active friendships with send_toggle ON enforced via count subquery in policy
- `photo_recipients` INSERT: service-role only (Edge Function); no client insert policy
- `face-profiles` bucket read: authenticated users can read only if an active friendship row exists between them and the file owner
- `friendship_keys` read/write: owner-scoped; each user can only read their own wrapped key copies
- `device_tokens`: fully owner-scoped
- `profiles`: publicly readable (display name, avatar, public key needed for friend request flow)

---

## Keypair & Encryption Architecture

### Per-user asymmetric keypair (photos)

```
Onboarding
  → KeyPairManager generates P-256 keypair
  → Private key stored in Keychain (kSecAttrAccessibleAfterFirstUnlock, iCloud Keychain sync ON)
  → Public key (DER base64) uploaded to profiles.public_key

At send time (AutoShareProcessor)
  → Fetch recipient's public key from profiles
  → Encrypt photo bytes to recipient public key (ECIES / CryptoKit)
  → Upload encrypted blob to `photos` bucket
  → Insert photos + photo_recipients rows (via Edge Function)

At receive time
  → Download encrypted blob via signed URL
  → Decrypt with own private key (CryptoKit)
  → Display / save to camera roll
```

### Symmetric key scheme (face reference photos)

```
Face profile setup (onboarding)
  → FaceProfileCrypto generates random 256-bit symmetric key (AES-GCM)
  → Reference photos encrypted with symmetric key on-device
  → Encrypted blobs uploaded to `face-profiles` bucket
  → Symmetric key wrapped to user's own public key → stored in face_profile_keys

On friendship acceptance (both sides)
  → User A's device: fetch B's encrypted reference photos + B's face_profile_keys entry
  → A's device wraps B's symmetric key to A's public key → upsert into friendship_keys
      (requires A's device to decrypt B's own-wrapped key — this works because A fetches
       B's face_profile_keys row which is wrapped to B's key; B's device must perform this
       wrapping step and push A's copy to friendship_keys as part of accepting/sending the request)
  → A downloads B's encrypted reference photos
  → A decrypts with B's symmetric key (now accessible via friendship_keys)
  → A runs MobileFaceNet pipeline → generates 512-D embeddings
  → A discards reference photos; stores only embeddings locally (FaceEnrollmentStore)

On face profile update
  → User generates new symmetric key, re-encrypts new reference photos, uploads
  → User's device re-wraps new symmetric key to each active friend's public key
  → Updates friendship_keys rows for all friends
  → Friends' devices detect stale embeddings on next sync → re-fetch, re-decrypt, re-embed

On unfriend
  → friendship_keys rows for both directions deleted
  → Friend loses read access to face-profiles bucket (RLS — no active friendship)
  → Both devices delete local embeddings for each other (FaceEnrollmentStore)
```

**Note on key wrapping flow:** When A sends a friend request, A cannot yet wrap B's symmetric key (the friendship isn't active). The wrapping step happens on acceptance: B's device wraps B's symmetric key to A's public key and pushes to `friendship_keys`. A's device wraps A's symmetric key to B's public key simultaneously. Both operations happen client-side at acceptance time; both devices must be online for this step.

---

## Photo Processing & Push Notification Pipeline

```
Photo captured on device
  → AutoShareProcessor wakes on app foreground
  → For each new asset (deduped by PHAsset.localIdentifier + perceptual hash):
      1. Load full-res image
      2. Normalize orientation, cap at 4096px
      3. Vision face detection over an image pyramid of 1024px tiles (small faces in wide shots), duplicates merged
      4. Re-detect landmarks on a crop of each face; warp eyes/nose/mouth onto the ArcFace 112×112 template
         (box-crop fallback if landmarks are missing/implausible, e.g. the Simulator)
      5. MobileFaceNet CoreML inference → 512-D embedding per face
      6. Compare embeddings to enrolled friends with Send toggle ON
         (cosine distance < 0.55 = match; unaligned faces get +0.2 penalty)
  → For each matching friend:
      ├─ If manual review ON for this friend:
      │    → Queue photo locally; no upload; badge review queue
      └─ If manual review OFF (default):
           → Fetch recipient's public key from profiles
           → Encrypt full-res photo on-device (ECIES via CryptoKit)
           → Upload encrypted blob to `photos` Supabase Storage
           → Call Edge Function: insert photos row + photo_recipients row
           → Edge Function looks up recipient APNs tokens
           → Edge Function sends HTTP/2 request to APNs
           → Recipient device receives push: "[Name] shared a photo with you"

Manual review approval
  → User approves photo for friend F in review queue
  → Same encrypt → upload → Edge Function → APNs flow as above
  → Rejected photos: discarded locally, never leave device
```

---

## Friend Request & Enrollment Pipeline

```
A generates invite link
  → Deep link URL with A's user_id + signed token
  → friendships row inserted with status=pending

B taps link → app opens → friendship acceptance screen
  → B accepts:
      → friendships.status = active
      → B's device: wraps B's symmetric key to A's public key → upsert friendship_keys (A's copy)
      → A's device: wraps A's symmetric key to B's public key → upsert friendship_keys (B's copy)
        (triggered by realtime subscription on friendships table)
      → send_toggles + receive_toggles rows inserted (both default true)
      → Both devices begin FaceEnrollmentSync:
          → Fetch other's encrypted reference photos from face-profiles bucket
          → Decrypt using friendship_keys symmetric key
          → MobileFaceNet pipeline → embeddings stored in FaceEnrollmentStore
          → Reference photos discarded
      → A notified: "[Name] accepted your friend request"
  → B declines:
      → friendships.status = declined
      → No keys exchanged, no enrollment
```

---

## Key Constraints

- **Face embeddings are never uploaded.** All face matching is on-device. The server receives only encrypted photo blobs — it cannot determine whether a face appears in them.
- **Reference photos are end-to-end encrypted.** Server stores encrypted blobs and wrapped key copies; it cannot decrypt either. No server-side face processing occurs.
- **Free tier limit: 3 friends with Send toggle ON.** Enforced server-side via Postgres RLS on `send_toggles` INSERT/UPDATE, not client-side only.
- **Keypair generated at onboarding — non-skippable.** No keypair = cannot send or receive encrypted content = cannot participate in the app.
- **Face profile setup is required — hard gate.** Cannot send or accept a friend request without having uploaded encrypted reference photos. Enforced client-side (onboarding gate) and server-side (Edge Function validates face_profile_keys exists before activating friendship).
- **Debug tools are TestFlight/debug builds only.** Face Match Sandbox screen must not ship in production builds. Gate with `#if DEBUG` or a build flag.

---

## Decision Log

See [`DECISIONS.md`](DECISIONS.md) for the full log. New decisions should be appended there (not here).

---

## Verification Harness

Lets Claude (or CI later) change the app and check it works without a human in the loop. See `scripts/verify/README.md`.

- `make verify` — `xcodegen`, then `PhotoShareTests` (hosted XCTest incl. the face-match pipeline over `PhotoShareTests/Fixtures/faces`) and a `PhotoShareUITests` launch smoke test on the iPhone 17 Pro simulator.
- `make scenario` — `scripts/verify/run_scenario.sh`: local Supabase in Docker (repo migrations + `supabase/seed_personas.sql`: Alice, Bob, Carol, Dan) and an end-to-end scenario across two simulators (one booted at a time; cap is 2), with evidence under `verification-output/` (gitignored).
- Debug builds read `PHOTOSHARE_SUPABASE_URL` / `PHOTOSHARE_SUPABASE_ANON_KEY` from the environment (see `SupabaseClient.swift`), so simulators can point at local Supabase without touching `Secrets.swift`.
- Face matching is evaluated on the Mac with real Vision landmarks (`scripts/verify/facematch-mac.sh`, no Simulator needed) because Simulator landmarks are unusable; evidence and limits in `docs/face-matching/README.md`. Enrollment key is `face_enrollment_v3_` (v2 vectors are incompatible).
- Face fixtures are AI-generated (non-real) portraits plus augmented variants: they guard pipeline regressions, not real-world recognition accuracy (threshold 15 was tuned on real device photos).
- On the Simulator, `FaceDetector` forces Vision to CPU and CoreML to `.cpuOnly`; the default compute units yield "Could not create inference context" (Vision) and an all-zero embedding (CoreML).
