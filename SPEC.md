# PhotoShare App — Product Specification

## Overview

PhotoShare is an iOS app that automatically shares photos to friends who appear in them. When a photo in your library contains a linked friend's face, the photo is instantly delivered to them — no manual sharing required.

---

## Core Concept

- Users link their account with specific friends (opt-in, bilateral)
- When a new photo is added to your camera roll containing a linked friend's face, it is automatically sent to that friend
- Recipients see photos they appear in delivered to their Photos tab in-app

---

## User Accounts

- Sign up via phone number (SMS verification)
- Profile: display name, profile photo, phone number
- Contacts sync (optional) to discover which contacts already have the app

---

## Friend Linking

### What it is
A **link** is a directional, opt-in connection from one user to another that enables auto-sharing. Both users must confirm before any photos flow, but each direction is configured independently.

### Directionality
- A link from A → B means: when A takes a photo containing B's face, it is automatically sent to B
- The reverse (B → A) is a separate link that B must independently initiate and A must independently accept
- After A's link request is accepted, A is prompted: "Do you also want [B] to auto-share photos of you with you?" — this shortcut pre-fills a return link request, but B must still send it and A must still accept
- Either direction can be active without the other

### Flow
1. User A sends a link request to User B (by phone number or from contacts)
   - The request specifies direction: "I want to send you photos when I see you in them"
2. User B receives a push notification and in-app prompt in the Friends tab: "User A wants to auto-share photos with you when they appear in them"
3. User B accepts or declines
4. On acceptance, the A → B link is active

### Rules
- Either user can remove a link direction at any time; removal is immediate and unilateral
- Removing a link does not delete previously shared photos
- Removing one direction does not affect the reverse direction
- A user can block another user, which removes all link directions between them and prevents future link requests

---

## Face Detection & Matching

- When new photos are added to the user's camera roll, the app processes them (on next app foreground if not running) to detect faces
- Detected faces are matched against the enrolled face profiles of the user's linked friends
- Matching happens on-device to preserve privacy; only matched friend IDs and the photo are sent to the server
- Face enrollment is re-prompted if matching accuracy degrades (e.g., after significant appearance changes)

### Face Enrollment Modes

Each linked friend must complete **face enrollment** before their face can be detected. There are two modes:

**Auto-enrollment** (when the friend has a face profile): If a friend has opted in to sharing their face profile, their reference photos are downloaded from the server to the capturing user's device, embeddings are generated locally, and enrollment completes automatically — no action required from the capturing user.

**Manual enrollment** (default): The capturing user selects 3–5 photos of the friend from their own photo library. A face embedding is generated on-device and stored locally. This is always available regardless of whether the friend has a face profile.

Embeddings are always generated on-device and never uploaded, regardless of which enrollment mode is used.

### Matching threshold
- A face must meet a confidence threshold (tunable server-side) to trigger a share
- If confidence is below threshold, no share is triggered — no false positives over missed shares
- Users can report a missed share ("this photo had my friend in it") to improve future matching

---

## Auto-Share Behavior

### Trigger
A share is triggered when:
1. A new photo is detected in the user's camera roll
2. At least one linked friend's face is detected above the confidence threshold

### What is shared
- The full-resolution photo
- Timestamp and location metadata from the photo (if location permission granted and user has location sharing enabled)
- The photo is shared only with friends whose faces were detected — not broadcast to all linked friends

### Delivery
- Photos are delivered via push notification: "Ryan shared a photo with you"
- The recipient opens the app to view the photo in the Photos tab
- Photos are stored in the recipient's in-app Photos tab

### Opt-out controls
- **Sending user** can disable auto-share globally (pauses all auto-sharing while off)
- **Sending user** can disable auto-share per friend (link stays intact but auto-share is paused for that friend)
- **Receiving user** can mute a specific friend (still linked, but no push notifications for their shares)
- **Receiving user** can turn off auto-receive globally (no photos are delivered while off)

---

## Photos Tab

- Chronological feed of all photos received from linked friends
- Each photo shows: sender name, timestamp, location (if shared), the photo, and a badge indicating whether the photo has been saved to the camera roll
- Tap to view full screen
- Long-press for options: save to camera roll, react with emoji, report
- Unread indicator per sender
- Photos are retained in-app for **30 days**, then deleted from servers (users can save to camera roll before expiry)
- A banner warns users 3 days before a photo expires

---

## Freemium Plan

### Free Tier
- Maximum **3 active outgoing links** at any time (links where you are the sender)
- Incoming links (others sending to you) are unlimited and free
- All core features available within the 3-link limit
- When at the limit: user can remove an outgoing link to free up a slot, or upgrade
- Attempting to send a link request at the 3-link limit shows an upgrade prompt

### Paid Tier (Pro)
- **Unlimited outgoing links** — the only differentiator from free

### Pricing
- Monthly and annual subscription options (prices TBD)
- Free trial: 7 days of Pro on new account creation
- Subscription managed via Apple In-App Purchase (StoreKit 2)
- Downgrade behavior: if a Pro user downgrades and has more than 3 outgoing links, existing outgoing links beyond 3 are preserved but paused (no auto-shares sent) until the user reduces active outgoing links to 3 or fewer; user is prompted to choose which 3 to keep active

---

## Permissions

The app requests the following iOS permissions:

| Permission | Why | When requested |
|---|---|---|
| Photo Library (read) | Detect faces in new photos to trigger auto-sharing | Onboarding / first auto-share attempt |
| Photo Library (add only) | Save received photos to camera roll | When user first taps "Save" |
| Contacts | Discover friends already on the app | Onboarding, optional |
| Face ID / On-device ML | Face matching (on-device only) | During face enrollment |
| Push Notifications | Deliver photo alerts | After completing onboarding |
| Location (when in use) | Attach location to shared photos | Only if user enables location sharing |

All permissions are requested contextually (not all at once on launch). Each request is preceded by an in-app explanation before the iOS system prompt.

---

## Face Profile (Optional)

Users can opt in to uploading a **face profile** — 3–5 reference photos of themselves stored in Supabase Storage. This enables auto-enrollment: when a friend links with them, the friend's device downloads these photos and generates face embeddings locally without any manual selection step.

- Opt-in is explicit and off by default; users can enable or disable it at any time from the Profile tab
- Disabling deletes all uploaded reference photos from the server immediately
- Friends who previously auto-enrolled from the face profile retain their local embeddings; to remove those, the link must be broken (which already triggers local enrollment data deletion per existing link-removal behavior)
- If a user has both a face profile and a friend who has manually enrolled them, the manual enrollment takes precedence (it is not overwritten by auto-enrollment)

---

## Privacy & Data

- Face embeddings (vector representations) are stored **locally on the capturing user's device only** — not uploaded to servers
- Users may opt in to uploading reference photos of themselves as a **face profile**; these photos are stored in Supabase Storage and used solely so friends' devices can generate embeddings locally — the server does not process or analyze them
- The server never receives face embeddings or performs any face analysis
- Photos are encrypted in transit (TLS) and at rest
- Users can delete their account, which purges all their sent and received photos from servers within 24 hours
- A user's face enrollment data is deleted from a friend's device when the link is broken
- Compliance: GDPR, CCPA, App Store privacy guidelines

---

## Notifications

| Event | Notification |
|---|---|
| Incoming link request | "[Name] wants to share photos with you" — appears as a card in the Friends tab requiring approval or decline |
| Link accepted | "[Name] accepted your link request" |
| Photo received | "[Name] shared a photo with you" (badge count increments) |
| Photo expiring soon | "A photo from [Name] expires in 3 days" |
| Pro trial ending | "Your free trial ends in 2 days" |

- Notification preferences configurable per-type in app settings
- Muting a friend suppresses photo-received notifications from them only

---

## Onboarding

1. **Welcome screen** — value prop: "Photos with your friends, automatically delivered"
2. **Phone number entry** → SMS verification
3. **Profile setup** — name, profile photo
4. **Face profile setup** — opt-in prompt: "Make it easy for friends to find you in their photos" with two explicit choices: "Share my face profile" (upload 3–5 photos) or "Keep it private" (manual enrollment only); both are presented as equally valid choices, not as "easy vs. hard"
5. **Photo Library permission prompt** — required to monitor camera roll for new photos to share
6. **Contacts permission prompt** — find friends on the app
7. **First link** — guided flow to send first link request or skip
8. **Face enrollment** — prompted after first link is accepted (can defer); auto-enrolls immediately if the friend has a face profile
9. **Notifications permission** — contextual prompt
10. **Home screen** (Photos tab, empty state with call to action)

---

## App Structure (Screens)

- **Photos** — chronological feed of all received photos; each photo shows a badge if already saved to camera roll (default tab)
- **Friends** — list of people you are currently sending photos to (outgoing links); surfaces pending incoming link requests as a card/banner with badge count on the tab; tap a friend to remove a link or manage face enrollment
- **Profile** — account settings, plan status, permissions; includes **My Face Profile** section to enable/disable face profile upload and manage reference photos

---

## Edge Cases & Rules

- If a photo contains multiple linked friends' faces, it is sent to all of them
- A photo is never shared with the person who took it, even if their own face appears in it
- If a share fails to deliver (network error), the app retries for up to 24 hours before dropping
- Duplicate sends are prevented: the same photo is not re-processed on subsequent app opens (deduplication by perceptual hash or asset identifier)
- A user under 13 cannot create an account (age gate at sign-up, parental consent flow TBD)
- Photos are processed on next app foreground if the app was not running when the photo was taken

---

## Out of Scope (v1)

- Android
- Group chats or threads
- Video sharing
- Reactions beyond emoji (comments, replies)
- Photo editing before share
- Web app
- Third-party sign-in (Apple ID, Google)
- Background photo processing (photos are processed when the app is next opened)
