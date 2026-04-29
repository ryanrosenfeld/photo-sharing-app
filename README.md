# PhotoShare

An iOS app that automatically shares photos to friends who appear in them. When a new photo in your camera roll contains a linked friend's face, it's instantly delivered to them — no manual sharing required.

Face matching runs entirely on-device. Embeddings never leave the device.

## Tech Stack

- **iOS 17+** — SwiftUI, Swift 6 strict concurrency
- **Backend** — Supabase (PostgreSQL, Auth, Storage)
- **Push Notifications** — APNs direct via Supabase Edge Functions
- **Face Detection** — Apple Vision (`VNDetectFaceRectanglesRequest`)
- **Face Recognition** — MobileFaceNet via CoreML (bundled `.mlpackage`, ArcFace-trained)
- **Project Generation** — XcodeGen (`project.yml` is source of truth)

## Getting Started

### Prerequisites

- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A [Supabase](https://supabase.com) project

### Setup

1. **Clone the repo**
   ```sh
   git clone https://github.com/ryanrosenfeld/photo-sharing-app.git
   cd photo-sharing-app
   ```

2. **Create `Secrets.swift`**
   ```sh
   cp Secrets.template.swift PhotoShare/Config/Secrets.swift
   ```
   Fill in your Supabase project URL and anon key. See `Secrets.template.swift` for the full setup instructions (Apple/Google auth, GoogleService-Info.plist).

3. **Run database migrations**
   Apply the migrations in `supabase/migrations/` to your Supabase project in order.

4. **Generate the Xcode project**
   ```sh
   xcodegen generate
   ```

5. **Open and run**
   ```sh
   open PhotoShare.xcodeproj
   ```
   Select a simulator or device and run.

## Project Structure

```
photo-sharing-app/
├── project.yml                  # XcodeGen config — edit this, not the .xcodeproj
├── Secrets.template.swift       # Reference for required API keys
├── SPEC.md                      # Full product specification
├── ARCHITECTURE.md              # Tech stack, data model, decision log
├── scripts/
│   └── convert_mobilefacenet.py # ONNX → CoreML conversion (one-time)
└── PhotoShare/
    ├── Auth/                    # Sign in with Apple, Google, email/password
    ├── Config/                  # Supabase client, Secrets
    ├── FaceMatch/               # On-device face detection, enrollment, matching
    ├── Resources/               # Bundled MobileFaceNet.mlpackage
    ├── Main/                    # Photos tab, Friends tab
    └── Models/                  # Shared data types
```

## Key Constraints

- **Face embeddings never leave the device.** All matching is on-device. The server only receives matched friend IDs and the photo.
- **Free tier: 3 active outgoing links.** Enforced server-side via Postgres RLS.
- **Links are directional.** A → B and B → A are independent and each require mutual opt-in.

## Docs

- [`SPEC.md`](SPEC.md) — product behavior, freemium model, edge cases
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — data model, auth flow, push notification architecture, decision log
