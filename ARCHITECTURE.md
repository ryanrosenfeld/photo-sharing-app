# PhotoShare — Architecture

## Overview

iOS-only SwiftUI app backed by Supabase (database, auth, storage) and Apple Push Notification service (APNs) for delivery. Face detection and recognition run entirely on-device — Vision for detection, a bundled MobileFaceNet CoreML model for identity embeddings.

---

## Tech Stack

| Layer | Technology | Notes |
|---|---|---|
| UI | SwiftUI | iOS 17+ deployment target |
| Language | Swift 6 | Strict concurrency enabled |
| Backend / DB | Supabase (PostgreSQL) | Hosted; see decision log |
| Auth | Supabase Auth | Apple, Google, email/password |
| File Storage | Supabase Storage | Photo uploads |
| Push Notifications | APNs (direct) | Via Supabase Edge Functions |
| Face Detection | Apple Vision (on-device) | `VNDetectFaceRectanglesRequest` for bounding boxes |
| Face Recognition | MobileFaceNet via CoreML | Bundled `.mlpackage`; 512-D ArcFace embeddings; on-device only |
| Project Generation | XcodeGen | `project.yml` is source of truth |
| Package Manager | Swift Package Manager | |

---

## Project Structure

```
photo-sharing-app/
├── project.yml                  # XcodeGen config — edit this, not the .xcodeproj
├── SPEC.md                      # Product spec
├── ARCHITECTURE.md              # This file
├── CLAUDE.md                    # Instructions for Claude sessions
├── Secrets.template.swift       # Copy → PhotoShare/Config/Secrets.swift and fill in
├── .gitignore
├── scripts/
│   └── convert_mobilefacenet.py # ONNX → CoreML conversion for the face model (one-time)
└── PhotoShare/
    ├── PhotoShareApp.swift      # @main entry point; wires Google Sign-In URL handler
    ├── ContentView.swift        # Root router: loading → auth → main app
    ├── Config/
    │   ├── Secrets.swift        # Gitignored; holds API keys
    │   └── SupabaseClient.swift # Global `supabase` singleton
    ├── Auth/                    # Apple / Google / Email auth flow
    ├── FaceMatch/
    │   ├── FaceDetector.swift            # Vision face detection + MobileFaceNet embedding
    │   ├── FaceEnrollmentStore.swift     # JSON persistence for [[Float]] embeddings
    │   ├── FaceEnrollmentView/VM.swift   # Enrollment UI + flow (auto / manual)
    │   ├── FaceProfileManager.swift      # Optional server-stored reference photos
    │   ├── PhotoLibraryManager.swift     # Camera roll cursor + permissions
    │   ├── AutoShareProcessor.swift      # End-to-end loop: detect → match → upload
    │   └── FaceMatchSandboxView/VM.swift # Debug-only screen for tuning the matcher
    ├── Resources/
    │   └── MobileFaceNet.mlpackage       # Bundled CoreML face recognition model
    └── Main/
        └── MainTabView.swift    # Tab shell + Profile tab
```

---

## Auth Flow

```
App launch
  └─ ContentView checks AuthManager.session
       ├─ loading   → ProgressView
       ├─ nil       → WelcomeView → AuthView
       │                 ├─ Sign in with Apple  (native ASAuthorization → Supabase idToken)
       │                 ├─ Sign in with Google (GIDSignIn → Supabase idToken)
       │                 └─ Email / Password    → EmailAuthView → Supabase signIn/signUp
       └─ present   → MainTabView
```

- Apple Sign In uses a SHA-256 nonce for replay protection (required by Supabase)
- Google Sign In uses the native GIDSignIn SDK; token passed directly to Supabase
- Supabase `authStateChanges` async stream keeps `AuthManager.session` live

---

## Data Model

See `supabase/migrations/20260425000000_initial_schema.sql` for the full schema with RLS policies.

```
profiles         id (→ auth.users), display_name, avatar_url, plan (free|pro),
                 face_profile_enabled (bool, default false)
links            id, sender_id, recipient_id, status (pending|active|paused|declined)
                 unique(sender_id, recipient_id) — directional, one row per direction
photos           id, sender_id, storage_path, taken_at, location_lat/lng, expires_at
photo_recipients (photo_id, recipient_id) PK, delivered_at, viewed_at
device_tokens    id, user_id, apns_token (unique)
```

**Supabase Storage buckets:**
- `photos` — shared photos (existing)
- `face-profiles` — optional user reference photos at path `{user_id}/{uuid}.jpg`; readable by authenticated users, writable only by the owner

**Key RLS rules:**
- `links` INSERT enforces the free tier 3-link limit via a count subquery in the policy
- `photo_recipients` INSERT is service-role only (Edge Function); no client insert policy
- `device_tokens` is fully owner-scoped
- `profiles` is publicly readable (needed for friend search)

---

## Photo Processing & Push Notification Pipeline

```
Photo captured on device
  → AutoShareProcessor wakes on app foreground
  → For each new asset:
      1. Load full-res image
      2. Downsample to 1024px (orientation-normalized) for face processing
      3. Vision face detection → bounding boxes
      4. Crop each face (with 25% padding) and resize to 112×112
      5. MobileFaceNet CoreML inference → 512-D embedding per face
      6. Compare embeddings to each enrolled friend (Euclidean distance)
  → If any match below threshold:
      → Upload full-res photo to Supabase Storage
      → Insert row into `photos` + `photo_recipients`
      → Supabase database trigger fires Edge Function
      → Edge Function looks up recipient APNs tokens
      → Edge Function sends HTTP/2 request to APNs
      → Recipient device receives push notification
```

---

## Key Constraints

- **Face embeddings are never uploaded.** All face matching is on-device only. The server only receives matched friend IDs + the photo. Users may opt in to uploading **reference photos** (not embeddings) to Supabase Storage so friends' devices can generate embeddings locally — no server-side face processing occurs.
- **Free tier limit is 3 active outgoing links.** Enforced server-side via Postgres RLS / Edge Function validation, not just client-side.
- **Links are directional.** A → B and B → A are independent rows in the `links` table.

---

## Decision Log

See [ARCHITECTURE.md — Decision Log](#decision-log) section below.

---

## Decision Log

### 2026-04-25 — Backend: Supabase over Firebase

**Decision:** Use Supabase (PostgreSQL) as the backend.

**Alternatives considered:** Firebase (Firestore), AWS Amplify.

**Reasoning:**
- The friend-link graph is inherently relational (directional edges with state). PostgreSQL handles this naturally with foreign keys, joins, and row-level security. Firestore's document model would require awkward denormalization.
- Supabase is open-source and self-hostable, reducing vendor lock-in risk.
- Predictable compute-based pricing vs. Firestore's per-read/write model, which can spike unexpectedly in a photo-sharing workload.

**Trade-off accepted:** Firebase's FCM is more mature for push notifications. Mitigated by going direct to APNs via Supabase Edge Functions, which keeps the stack unified and costs zero.

---

### 2026-04-25 — Push Notifications: APNs direct over FCM / OneSignal

**Decision:** Send push notifications directly to APNs from Supabase Edge Functions.

**Alternatives considered:** FCM (Firebase Cloud Messaging), OneSignal, Novu.

**Reasoning:**
- Keeps the entire backend in one place (no extra vendor).
- APNs HTTP/2 API is well-documented and not complex for a single notification type.
- Zero per-notification cost.
- FCM would re-introduce a Google dependency after choosing Supabase specifically to avoid Firebase lock-in.

**Trade-off accepted:** We own the token registration and retry logic. FCM handles these automatically. Acceptable complexity for the control gained.

---

### 2026-04-25 — Removed in-app camera; switched to photo library monitoring

**Decision:** Remove the in-app camera. The app monitors the user's native camera roll for new photos instead.

**Reasoning:**
- Reduces friction — users shouldn't need to switch to a separate camera app.
- Simplifies the app surface area; camera UX is a solved problem in iOS.
- Requires Photo Library read permission (previously only add-only was needed).
- Photos are processed on next app foreground (background processing is out of scope for v1).

**Trade-off accepted:** We lose instant processing at capture time. There's a delay between taking a photo and it being shared, bounded by when the user next opens the app.

---

### 2026-04-25 — Merged Inbox into Photos tab; moved link requests to Friends tab

**Decision:** Replace the Inbox + Camera tabs with a single Photos tab. Pending link requests surface in the Friends tab (badged) rather than the Inbox.

**Reasoning:**
- The Photos tab is optimized for quickly reviewing and saving received photos — a more focused UX.
- Link requests are relationship-management actions; Friends is the natural home.

---

### 2026-04-28 — Face recognition: MobileFaceNet (CoreML) over VNGenerateImageFeaturePrintRequest

**Decision:** Bundle a MobileFaceNet CoreML model (insightface buffalo_sc / `w600k_mbf`, ArcFace-trained) for face identity embeddings. Vision is still used for face detection (`VNDetectFaceRectanglesRequest`).

**Alternatives considered:** continuing with `VNGenerateImageFeaturePrintRequest`, FaceNet via CoreML, Create ML custom classifier, ARKit/TrueDepth.

**Reasoning:**
- `VNGenerateImageFeaturePrintRequest` is a general-purpose image similarity model, not a face recognition model. Same-person and different-person distance distributions overlapped in practice — no clean threshold existed.
- MobileFaceNet was trained specifically with ArcFace loss to maximize the margin between same-identity and different-identity pairs. ~4 MB model; runs in ~25ms on A-series chips.
- Apple has no public face *identity* API. Photos uses a private `PersonsUI` framework that is not exposed to third-party apps.
- Create ML can only train classifiers over a fixed set of people; doesn't fit the open-set, per-friendship enrollment model.

**Implementation notes:**
- Pipeline: Vision detects face bounding box → crop with 25% padding → resize to 112×112 → CoreML inference → 512-D `[Float]` embedding
- Images are normalized to `.up` orientation and downsampled to 1024px before processing (full-res photos OOM the device)
- Enrollments are stored under a `face_enrollment_v2_` UserDefaults key prefix; old `VNFeaturePrintObservation` enrollments are silently ignored
- The model file lives at `PhotoShare/Resources/MobileFaceNet.mlpackage`. Conversion is reproducible via `scripts/convert_mobilefacenet.py` (ONNX → PyTorch → CoreML)
- A debug-only Face Match Sandbox screen (Profile → Debug → Face Match Sandbox) lets us inspect raw distances, face crops, and threshold behavior interactively

**Trade-off accepted:** Embeddings are not L2-normalized at the model's output layer, so raw Euclidean distances live in a wider numeric range (~5–25) than for typical normalized models. The threshold is empirically tuned rather than landing in the textbook 0.3–0.4 range.

---

### 2026-04-28 — Face enrollment: dual-mode (auto from face profile vs. manual)

**Decision:** Support two face enrollment paths: auto-enrollment via the friend's uploaded face profile, and manual enrollment where the capturing user selects photos themselves.

**Reasoning:**
- Manual enrollment (original design) puts the burden on every user to find and upload photos of each friend they link with. This doesn't scale as the friend graph grows.
- A face profile (opt-in server-side reference photos) lets each user enroll themselves once; any friend who links with them gets automatic enrollment without any action.
- Opt-in is essential: storing photos of yourself server-side is a meaningfully different privacy decision than purely on-device processing. The choice must be explicit and reversible.

**Privacy model:**
- Reference photos are stored in Supabase Storage (`face-profiles/{user_id}/`), readable by authenticated users.
- Embeddings are always generated on the downloading friend's device — the server never processes or analyzes the photos.
- Disabling the face profile deletes all reference photos from Storage immediately.

**Trade-off accepted:** Users who opt out of the face profile still require friends to manually enroll them. The two-path model adds UI complexity (mode picker in FaceEnrollmentView, face profile management in ProfileView) but avoids social pressure to opt in by presenting both modes as equally valid.

---

### 2026-04-25 — Auth: Apple + Google + Email/Password

**Decision:** Support Sign in with Apple, Sign in with Google, and email/password.

**Reasoning:**
- App Store guideline requires Sign in with Apple if any third-party OAuth is offered (Google qualifies), so Apple is mandatory.
- Google is the most common OAuth provider and expected by users.
- Email/password for users who prefer it or don't have/want Google.

**Note:** Phone number auth (originally in spec) was dropped in favor of email for lower friction and no SMS cost in early stages.
